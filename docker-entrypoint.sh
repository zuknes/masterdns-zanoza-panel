#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${ZANOZA_CONFIG_DIR:-/etc/zanoza-panel}"
CONFIG_PATH="${CONFIG_DIR}/config.json"
RENEW_MARKER="${CONFIG_DIR}/.renew-self-signed"

mkdir -p "$CONFIG_DIR"

PORT="${ZANOZA_PANEL_PORT:-8443}"
ADDR="${ZANOZA_PANEL_ADDR:-0.0.0.0}"
PANEL_PATH="${ZANOZA_PANEL_PATH:-/admin}"
NAME="${ZANOZA_NAME:-Zanoza Panel}"
TLS_CERT="${ZANOZA_TLS_CERT:-}"
TLS_KEY="${ZANOZA_TLS_KEY:-}"

# Preserve existing instances if config.json already exists.
INSTANCES="[]"
if [ -f "$CONFIG_PATH" ] && command -v jq >/dev/null 2>&1; then
	INSTANCES="$(jq -c '.instances // []' "$CONFIG_PATH" 2>/dev/null || echo "[]")"
fi

# Generate config.json from current env vars.
jq -n \
	--arg name "$NAME" \
	--arg addr "$ADDR" \
	--arg port "$PORT" \
	--arg path "$PANEL_PATH" \
	--arg cert "$TLS_CERT" \
	--arg key "$TLS_KEY" \
	--argjson instances "$INSTANCES" \
'{
	version: 1,
	name: $name,
	panel_addr: $addr,
	panel_port: ($port | tonumber),
	panel_path: $path,
} + (if ($cert != "" and $key != "") then {tls_cert: $cert, tls_key: $key} else {} end)
 + {instances: $instances}' > "$CONFIG_PATH"

# Self-signed cert auto-renewal via crond (only when marker file exists).
if [ -f "$RENEW_MARKER" ]; then
	pkill -x crond 2>/dev/null || true
	sleep 1
	echo "0 3 * * * /usr/local/bin/docker-renew-cert.sh >>/proc/1/fd/1 2>&1" | crontab -
	# crond runs in the background; after the exec below it will be reparented
	# to tini (PID 1), which properly reaps orphans and forwards signals.
	# BusyBox crond captures cron-job output for mailing (no MTA → lost).
	# Redirect to /proc/1/fd/{1,2} so docker-renew-cert.sh logs appear in docker logs.
	crond -L /dev/null
fi

exec zanoza-panel -config "$CONFIG_PATH"
