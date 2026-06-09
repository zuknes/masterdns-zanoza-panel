FROM golang:1.25-alpine AS builder

ENV GOTOOLCHAIN=local
ENV GODEBUG=netdns=go

# Prefer IPv4 (safe on both glibc and musl).
RUN touch /etc/gai.conf && echo 'precedence ::ffff:0:0/96  100' >> /etc/gai.conf

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download

COPY cmd/ ./cmd/
COPY tools/ ./tools/

RUN CGO_ENABLED=0 go build -o /out/zanoza-panel ./cmd/zanoza-panel

WORKDIR /src/masterdns
COPY masterdns/go.mod masterdns/go.sum ./
RUN go mod download

COPY masterdns/ ./

RUN CGO_ENABLED=0 go build -o /out/masterdns-server ./cmd/server

FROM alpine:3.21

RUN apk add --no-cache ca-certificates tini bash openssl jq busybox curl

COPY --from=builder /out/zanoza-panel /usr/local/bin/
COPY --from=builder /out/masterdns-server /usr/local/bin/

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/docker-entrypoint.sh

# Self-signed cert renewal helper (daily via crond).
COPY docker-renew-cert.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/docker-renew-cert.sh

WORKDIR /opt/zanoza

ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/docker-entrypoint.sh"]
