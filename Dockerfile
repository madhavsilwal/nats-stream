# syntax=docker/dockerfile:1
FROM nats:2.12-alpine AS base

FROM golang:1.26-alpine AS builder
RUN apk add --no-cache git \
    && go install github.com/nats-io/nsc/v2@v2.12.0

FROM base
COPY --from=builder /go/bin/nsc /usr/local/bin/nsc

RUN apk add --no-cache curl \
    && ARCH=$(uname -m) \
    && case "$ARCH" in \
         x86_64)  YQ_ARCH=amd64 ;; \
         aarch64) YQ_ARCH=arm64 ;; \
         *)       echo "unsupported arch: $ARCH" && exit 1 ;; \
       esac \
    && YQ_VERSION=v4.44.6 \
    && curl -fsSL "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${YQ_ARCH}" -o /usr/local/bin/yq \
    && chmod +x /usr/local/bin/yq \
    && apk del curl

COPY nats.conf       /etc/nats/nats.conf
COPY entrypoint.sh   /entrypoint.sh
COPY entities.yaml   /etc/nats/entities.yaml
RUN chmod +x /entrypoint.sh

EXPOSE 4222 6222 8222
ENTRYPOINT ["/entrypoint.sh"]
