FROM golang:1.26-alpine AS builder

WORKDIR /app
COPY go.mod .
COPY cmd/server/ cmd/server/
RUN go build -o server ./cmd/server

FROM alpine:latest

WORKDIR /app
COPY --from=builder /app/server .

EXPOSE 8080

CMD ["./server"]
