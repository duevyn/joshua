package main

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"go.opentelemetry.io/contrib/bridges/otelslog"
	"go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
	"go.opentelemetry.io/otel/log/global"
	"go.opentelemetry.io/otel/propagation"
	sdklog "go.opentelemetry.io/otel/sdk/log"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

const serviceName = "joshua-server"

func initOTEL(ctx context.Context) (shutdown func(context.Context) error, err error) {
	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(getEnv("OTEL_SERVICE_NAME", serviceName)),
			semconv.ServiceVersion(getEnv("APP_VERSION", "dev")),
			semconv.DeploymentEnvironmentKey.String(getEnv("APP_ENV", "dev")),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("create OTEL resource: %w", err)
	}

	// Traces
	traceExporter, err := otlptracegrpc.New(ctx)
	if err != nil {
		return nil, fmt.Errorf("create trace exporter: %w", err)
	}
	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(traceExporter),
		sdktrace.WithResource(res),
		sdktrace.WithSampler(sdktrace.AlwaysSample()),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
		propagation.TraceContext{},
		propagation.Baggage{},
	))

	// Metrics
	metricExporter, err := otlpmetricgrpc.New(ctx)
	if err != nil {
		return nil, errors.Join(
			fmt.Errorf("create metric exporter: %w", err),
			tp.Shutdown(ctx),
		)
	}
	mp := sdkmetric.NewMeterProvider(
		sdkmetric.WithReader(sdkmetric.NewPeriodicReader(metricExporter,
			sdkmetric.WithInterval(15*time.Second),
		)),
		sdkmetric.WithResource(res),
	)
	otel.SetMeterProvider(mp)

	// Logs — third pillar. Exports OTLP/gRPC to the collector so slog records
	// written via the otelslog bridge end up in Loki alongside traces and metrics.
	logExporter, err := otlploggrpc.New(ctx)
	if err != nil {
		return nil, errors.Join(
			fmt.Errorf("create log exporter: %w", err),
			tp.Shutdown(ctx),
			mp.Shutdown(ctx),
		)
	}
	lp := sdklog.NewLoggerProvider(
		sdklog.WithProcessor(sdklog.NewBatchProcessor(logExporter)),
		sdklog.WithResource(res),
	)
	global.SetLoggerProvider(lp)

	return func(ctx context.Context) error {
		return errors.Join(tp.Shutdown(ctx), mp.Shutdown(ctx), lp.Shutdown(ctx))
	}, nil
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

func main() {
	// Bootstrap: stderr JSON logger from the very first line so any pre-OTel
	// failure is captured in structured form by kubectl/docker logs.
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo})))

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	shutdown, err := initOTEL(ctx)
	if err != nil {
		slog.Error("init OTEL failed", "error", err)
		os.Exit(1)
	}
	defer func() {
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := shutdown(shutdownCtx); err != nil {
			slog.Error("OTEL shutdown failed", "error", err)
		}
	}()

	// Upgrade the default logger to a fan-out: every record goes to stderr
	// (so kubectl/docker logs still works even if the collector is unreachable)
	// AND to the OTel log pipeline (so records land in Loki). The otelslog
	// bridge automatically stamps each record with the active trace_id and
	// span_id, giving Grafana click-through correlation between logs and traces.
	slog.SetDefault(slog.New(newFanoutHandler(
		slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{Level: slog.LevelInfo}),
		otelslog.NewHandler(serviceName),
	)))

	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// InfoContext carries the otelhttp span context, so the record is
		// automatically stamped with trace_id/span_id by the otelslog bridge.
		slog.InfoContext(r.Context(), "hello world request",
			"method", r.Method,
			"path", r.URL.Path,
			"remote", r.RemoteAddr,
			"user_agent", r.UserAgent(),
		)
		if _, err := fmt.Fprintln(w, "Hello, World!"); err != nil {
			slog.WarnContext(r.Context(), "write response failed", "error", err)
		}
	})
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
	})

	// Wrap mux with OTEL HTTP middleware — records span + http.server.* metrics
	handler := otelhttp.NewHandler(mux, serviceName,
		otelhttp.WithMessageEvents(otelhttp.ReadEvents, otelhttp.WriteEvents),
	)

	srv := &http.Server{
		Addr:         ":8080",
		Handler:      handler,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 10 * time.Second,
		IdleTimeout:  30 * time.Second,
	}

	go func() {
		slog.Info("server listening", "addr", srv.Addr)
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			slog.Error("server crashed", "error", err)
			os.Exit(1)
		}
	}()

	<-ctx.Done()
	slog.Info("shutdown signal received, draining")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		slog.Error("server shutdown failed", "error", err)
	}
}

// fanoutHandler dispatches every slog record to multiple downstream handlers,
// letting us write structured logs to stderr (for kubectl/docker logs) and to
// the OTel log pipeline (for Loki) without losing either if one stalls.
// It implements the full slog.Handler contract, propagating WithAttrs/WithGroup
// to every child so `slog.With(...)` chains work across both sinks.
type fanoutHandler struct {
	handlers []slog.Handler
}

func newFanoutHandler(handlers ...slog.Handler) *fanoutHandler {
	return &fanoutHandler{handlers: handlers}
}

func (f *fanoutHandler) Enabled(ctx context.Context, level slog.Level) bool {
	for _, h := range f.handlers {
		if h.Enabled(ctx, level) {
			return true
		}
	}
	return false
}

func (f *fanoutHandler) Handle(ctx context.Context, r slog.Record) error {
	var errs []error
	for _, h := range f.handlers {
		if !h.Enabled(ctx, r.Level) {
			continue
		}
		// Clone so handlers that mutate the record (e.g. adding attrs) don't
		// interfere with siblings seeing the same value.
		if err := h.Handle(ctx, r.Clone()); err != nil {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

func (f *fanoutHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
	children := make([]slog.Handler, len(f.handlers))
	for i, h := range f.handlers {
		children[i] = h.WithAttrs(attrs)
	}
	return &fanoutHandler{handlers: children}
}

func (f *fanoutHandler) WithGroup(name string) slog.Handler {
	children := make([]slog.Handler, len(f.handlers))
	for i, h := range f.handlers {
		children[i] = h.WithGroup(name)
	}
	return &fanoutHandler{handlers: children}
}
