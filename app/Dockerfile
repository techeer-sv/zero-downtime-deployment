FROM golang:1.24-alpine AS builder
WORKDIR /app
COPY . .
RUN go build -o server .

FROM alpine:3.21
ARG APP_VERSION=unknown
ENV APP_VERSION=$APP_VERSION
WORKDIR /app
COPY --from=builder /app/server .
EXPOSE 8080
CMD ["./server"]
