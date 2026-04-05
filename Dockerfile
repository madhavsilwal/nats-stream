# syntax=docker/dockerfile:1
FROM nats:2.12-alpine AS base

FROM golang:1.26-alpine AS builder
RUN apk add --no-cache git \
    && go install github.com/nats-io/nsc/v2@latest

FROM base
COPY --from=builder /go/bin/nsc /usr/local/bin/nsc
COPY nats.conf       /etc/nats/nats.conf
COPY entrypoint.sh   /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 4222 6222 8222
ENTRYPOINT ["/entrypoint.sh"]