#!/usr/bin/env bash
# Daily self-signed cert renewal (triggered by crond inside the container).
# Only runs when ZANOZA_TLS_CERT / ZANOZA_TLS_KEY are set and files are
# managed by the container (not externally mounted certs like LE).
# All output goes to stdout/stderr — captured by docker logs.
set -euo pipefail

log()  { printf '[zanoza-renew-cert] %s\n' "$*"; }
warn() { printf '[zanoza-renew-cert] WARN: %s\n' "$*" >&2; }

CERT="${ZANOZA_TLS_CERT:-}"
KEY="${ZANOZA_TLS_KEY:-}"
RENEW_MARKER="/etc/zanoza-panel/.renew-self-signed"

[ -f "$RENEW_MARKER" ] || exit 0
[ -n "$CERT" ] && [ -n "$KEY" ] || exit 0

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
if [ -z "$IP" ]; then
	warn "Cannot determine server IP — skipping renewal."
	exit 1
fi

log "Renewing self-signed certificate for ${IP}..."

if openssl req -x509 -newkey rsa:2048 -nodes -days 6 \
	-keyout "$KEY" -out "$CERT" \
	-subj "/CN=${IP}" -addext "subjectAltName=IP:${IP}" 2>/dev/null; then
	log "Certificate renewed (with SAN)."
elif openssl req -x509 -newkey rsa:2048 -nodes -days 6 \
	-keyout "$KEY" -out "$CERT" -subj "/CN=${IP}" 2>/dev/null; then
	log "Certificate renewed (no SAN, older openssl)."
else
	warn "Certificate renewal FAILED — openssl exited with error."
	exit 1
fi

chmod 600 "$KEY"

# Signal the panel to restart so it picks up the new cert.
# Docker restarts the container automatically (restart: unless-stopped).
if pkill zanoza-panel 2>/dev/null; then
	sleep 2
	log "Panel signalled to restart."
else
	warn "Could not signal zanoza-panel — the container may need a manual restart."
	exit 1
fi
