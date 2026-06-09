#!/usr/bin/env bash
# ==============================================================================
# zanoza-common — shared helpers for Zanoza Panel scripts
# Sourced by docker-install.sh, zanoza-docker, zanoza, install.sh
# ==============================================================================

die()  { printf '\033[1;31m[zanoza] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
log()  { printf '\033[1;32m[zanoza]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[zanoza]\033[0m %s\n' "$*"; }

read_tty() {
	local prompt="$1" def="${2:-}"
	local reply
	if [ -r /dev/tty ]; then
		read -r -p "$prompt" reply </dev/tty || reply="$def"
	else
		reply="$def"
	fi
	printf '%s' "${reply:-$def}"
}

random_alnum() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$1"; }

# --------------------------------------------------------------------------
# Shared certificate helpers — used by docker-install.sh and zanoza-docker.
# --------------------------------------------------------------------------

# Generate a self-signed X.509 certificate valid for DAYS days.
# Usage: generate_self_signed_cert <cert-file> <key-file> <ip> [days]
# Returns non-zero on failure.
generate_self_signed_cert() {
	local cert="$1" key="$2" ip="$3" days="${4:-6}"
	mkdir -p "$(dirname "$cert")"
	if openssl req -x509 -newkey rsa:2048 -nodes -days "$days" \
		-keyout "$key" -out "$cert" \
		-subj "/CN=${ip}" -addext "subjectAltName=IP:${ip}" 2>/dev/null; then
		:
	elif openssl req -x509 -newkey rsa:2048 -nodes -days "$days" \
		-keyout "$key" -out "$cert" \
		-subj "/CN=${ip}" 2>/dev/null; then
		:
	else
		return 1
	fi
	chmod 600 "$key"
	chmod 644 "$cert"
}

# Install acme.sh if not already present, setting the default CA to Let's Encrypt.
# Usage: ensure_acme_sh <email>
ensure_acme_sh() {
	local email="$1"
	if [ ! -f ~/.acme.sh/acme.sh ]; then
		curl -fsSL https://get.acme.sh | sh -s email="$email" >/dev/null 2>&1 || {
			warn "acme.sh install had warnings. Continuing anyway."
		}
	fi
	~/.acme.sh/acme.sh --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
}

# Issue a Let's Encrypt certificate via standalone mode (port 80 must be free).
# Usage: issue_letsencrypt_cert <domain> <cert-file> <key-file> <reload-cmd>
# Returns non-zero on failure.
issue_letsencrypt_cert() {
	local domain="$1" cert="$2" key="$3" reload_cmd="$4"
	ensure_acme_sh "admin@${domain}"
	if ~/.acme.sh/acme.sh --issue --standalone -d "$domain" >/dev/null 2>&1; then
		mkdir -p "$(dirname "$cert")"
		~/.acme.sh/acme.sh --install-cert -d "$domain" \
			--key-file "$key" --fullchain-file "$cert" \
			--reloadcmd "$reload_cmd" >/dev/null 2>&1
		chmod 600 "$key"
		chmod 644 "$cert"
		return 0
	else
		return 1
	fi
}
