#!/usr/bin/env bash
# ==============================================================================
# zanoza-common — shared helpers for Zanoza Panel scripts
# Sourced by container-install.sh, zanoza, install.sh
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
# Container runtime detection
# --------------------------------------------------------------------------

# Check if Docker daemon + compose are available and working.
has_docker() {
	command -v docker >/dev/null 2>&1 || return 1
	( docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1 ) || return 1
	docker info >/dev/null 2>&1
}

# Check if podman is installed at all.
has_podman() {
	command -v podman >/dev/null 2>&1
}

# Returns podman version string (e.g. "4.9.3") or empty.
get_podman_version() {
	podman version --format '{{.Version}}' 2>/dev/null || echo ""
}

# Compare two version strings. Returns 0 (true) if $1 >= $2.
version_gte() {
	[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | tail -1)" = "$1" ]
}

# Does the installed podman support Quadlets? (needs >= 4.4)
podman_supports_quadlet() {
	local ver
	ver="$(get_podman_version)"
	[ -n "$ver" ] && version_gte "$ver" "4.4"
}

# --------------------------------------------------------------------------
# SELinux helpers
# --------------------------------------------------------------------------

# Returns 0 when SELinux is enforcing.
is_selinux_enforcing() {
	command -v getenforce >/dev/null 2>&1 && [ "$(getenforce 2>/dev/null)" = "Enforcing" ]
}

# Returns ":Z" for volume mounts — safe no-op when SELinux not enforcing.
selinux_volume_flag() { is_selinux_enforcing && printf ':Z'; }

# --------------------------------------------------------------------------
# Container operation wrappers
#
# These expect the following env vars / globals to be set:
#   CONTAINER_RUNTIME  = docker | podman
#   REPO_DIR           = repository root
#   UNIT_NAME          = systemd unit name (podman only: zanoza-panel for
#                        quadlet, container-zanoza-panel for generate-systemd)
#   COMPOSE_FILE       = path to docker-compose.yml (default: REPO_DIR/docker-compose.yml)
# --------------------------------------------------------------------------

container_build() {
	case "${CONTAINER_RUNTIME:?}" in
		docker)
			docker compose -f "${COMPOSE_FILE:-$REPO_DIR/docker-compose.yml}" build
			;;
		podman)
			( cd "${REPO_DIR:?}" && podman build -t zanoza-panel . )
			;;
		*) die "container_build: unknown CONTAINER_RUNTIME=${CONTAINER_RUNTIME}" ;;
	esac
}

container_start() {
	case "${CONTAINER_RUNTIME:?}" in
		docker)
			docker compose -f "${COMPOSE_FILE:-$REPO_DIR/docker-compose.yml}" up -d
			;;
		podman)
			systemctl start "${UNIT_NAME:?}"
			;;
		*) die "container_start: unknown CONTAINER_RUNTIME=${CONTAINER_RUNTIME}" ;;
	esac
}

container_restart() {
	case "${CONTAINER_RUNTIME:?}" in
		docker)
			docker compose -f "${COMPOSE_FILE:-$REPO_DIR/docker-compose.yml}" restart
			;;
		podman)
			systemctl restart "${UNIT_NAME:?}"
			;;
		*) die "container_restart: unknown CONTAINER_RUNTIME=${CONTAINER_RUNTIME}" ;;
	esac
}

container_stop() {
	case "${CONTAINER_RUNTIME:?}" in
		docker)
			docker compose -f "${COMPOSE_FILE:-$REPO_DIR/docker-compose.yml}" stop
			;;
		podman)
			systemctl stop "${UNIT_NAME:?}"
			;;
		*) die "container_stop: unknown CONTAINER_RUNTIME=${CONTAINER_RUNTIME}" ;;
	esac
}

container_down() {
	case "${CONTAINER_RUNTIME:?}" in
		docker)
			docker compose -f "${COMPOSE_FILE:-$REPO_DIR/docker-compose.yml}" down --remove-orphans
			;;
		podman)
			podman rm -f zanoza-panel 2>/dev/null || true
			;;
		*) die "container_down: unknown CONTAINER_RUNTIME=${CONTAINER_RUNTIME}" ;;
	esac
}

container_logs() {
	case "${CONTAINER_RUNTIME:?}" in
		docker)
			docker compose -f "${COMPOSE_FILE:-$REPO_DIR/docker-compose.yml}" logs -f
			;;
		podman)
			journalctl -fu "${UNIT_NAME:?}"
			;;
		*) die "container_logs: unknown CONTAINER_RUNTIME=${CONTAINER_RUNTIME}" ;;
	esac
}

container_status() {
	case "${CONTAINER_RUNTIME:?}" in
		docker)
			docker compose -f "${COMPOSE_FILE:-$REPO_DIR/docker-compose.yml}" ps --quiet 2>/dev/null | grep -q .
			;;
		podman)
			systemctl is-active --quiet "${UNIT_NAME:?}" 2>/dev/null
			;;
		*) return 1 ;;
	esac
}

# Returns the command to reload/restart the panel (used by cert renewal).
# Requires CONTAINER_RUNTIME and UNIT_NAME (for podman) to be set.
get_reload_cmd() {
	case "${CONTAINER_RUNTIME:-}" in
		docker)
			printf 'docker compose -f %s restart' "${COMPOSE_FILE:-$REPO_DIR/docker-compose.yml}"
			;;
		podman)
			printf 'systemctl restart %s' "${UNIT_NAME:-zanoza-panel}"
			;;
		*) echo "true" ;;
	esac
}

# --------------------------------------------------------------------------
# Shared certificate helpers — used by container-install.sh and zanoza.
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
