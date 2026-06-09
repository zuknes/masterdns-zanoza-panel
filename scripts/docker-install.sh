#!/usr/bin/env bash
# ==============================================================================
# Zanoza Panel — Docker installer (any Linux, run as root).
#   curl -fsSL https://raw.githubusercontent.com/zuknes/masterdns-zanoza-panel/feature/docker-setup/scripts/docker-install.sh | sudo bash
#
# Checks Docker, frees port 53, prompts for credentials, writes panel.env,
# builds the image locally and starts the panel via docker compose.
# ==============================================================================
set -euo pipefail

REPO_URL="https://github.com/zuknes/masterdns-zanoza-panel.git"
REPO_DEFAULT_DIR="/opt/zanoza-panel"

# ==========================================================================
# Package manager detection & auto-install of missing system packages.
# (runs before we source zanoza-common.sh, so uses bare printf/exit).
# ==========================================================================
detect_pkg_manager() {
	if command -v apt-get >/dev/null 2>&1; then echo "apt-get"
	elif command -v dnf >/dev/null 2>&1; then echo "dnf"
	elif command -v yum >/dev/null 2>&1; then echo "yum"
	elif command -v pacman >/dev/null 2>&1; then echo "pacman"
	elif command -v zypper >/dev/null 2>&1; then echo "zypper"
	elif command -v apk >/dev/null 2>&1; then echo "apk"
	else echo ""; fi
}

pkg_install() {
	local pkg="$1"; shift
	case "$pkg" in
		apt-get) apt-get update -qq && apt-get install -y -qq "$@";;
		dnf)     dnf install -y -q "$@";;
		yum)     yum install -y -q "$@";;
		pacman)  pacman -S --noconfirm --quiet "$@";;
		zypper)  zypper --quiet install -y "$@";;
		apk)     apk add --no-cache "$@";;
		*)       return 1;;
	esac
}

ensure_packages() {
	local pkg missing_pkgs ans
	pkg="$(detect_pkg_manager)"

	missing_pkgs=""
	command -v git >/dev/null 2>&1     || missing_pkgs="$missing_pkgs git"
	command -v openssl >/dev/null 2>&1 || missing_pkgs="$missing_pkgs openssl"

	if [ -z "$missing_pkgs" ]; then
		return 0
	fi

	if [ -z "$pkg" ]; then
		printf '\033[1;31mERROR:\033[0m missing packages:%s\n' "$missing_pkgs" >&2
		printf 'Could not detect package manager. Install them manually and re-run.\n' >&2
		exit 1
	fi

	printf '\033[1;33m[zanoza]\033[0m Missing packages detected:%s\n' "$missing_pkgs"
	printf 'Install via %s? [Y/n]: ' "$pkg"
	read -r ans </dev/tty || ans="Y"
	case "$ans" in
		y|Y|"") ;;
		*)
			printf '\033[1;31mERROR:\033[0m cannot continue without required packages.\n' >&2
			exit 1
			;;
	esac

	printf '\033[1;32m[zanoza]\033[0m Installing:%s\n' "$missing_pkgs"
	pkg_install "$pkg" $missing_pkgs || {
		printf '\033[1;31mERROR:\033[0m package installation failed.\n' >&2
		exit 1
	}
	printf '\033[1;32m[zanoza]\033[0m Packages installed.\n'
}

# --------------------------------------------------------------------------
# Locate (or clone) the repository
# --------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ -f "${SCRIPT_DIR}/../docker-compose.yml" ]; then
	# Running from inside a cloned repo.
	REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
else
	# Piped from curl into bash. Ensure git/openssl are available first.
	ensure_packages

	REPO_DIR="$REPO_DEFAULT_DIR"
	if [ -d "$REPO_DIR/.git" ]; then
		printf '\033[1;33m[zanoza]\033[0m %s already exists, pulling latest...\n' "$REPO_DIR"
		git -C "$REPO_DIR" pull 2>/dev/null || true
	elif [ -d "$REPO_DIR" ]; then
		printf '\033[1;33m[zanoza]\033[0m %s exists but is not a git repo — replacing.\n' "$REPO_DIR"
		rm -rf "$REPO_DIR"
	fi
	if [ ! -d "$REPO_DIR" ]; then
		printf '\033[1;32mCloning repository into %s ...\033[0m\n' "$REPO_DIR"
		git clone --depth 1 --branch feature/docker-setup "$REPO_URL" "$REPO_DIR" || {
			printf '\033[1;31mERROR:\033[0m git clone failed.\n' >&2
			exit 1
		}
	fi
fi

# Now source helpers from the repo (always found).
# shellcheck source=./zanoza-common.sh
. "${REPO_DIR}/scripts/zanoza-common.sh"

[ "$(id -u)" -eq 0 ] || die "run as root (sudo)."

CONFIG_DIR="${REPO_DIR}/zanoza-config"
ENV_FILE="${REPO_DIR}/.env"
ENV_EXAMPLE="${REPO_DIR}/.env.example"
CERT_DIR="${CONFIG_DIR}"
CERT_FILE="${CERT_DIR}/tls.crt"
KEY_FILE="${CERT_DIR}/tls.key"

# --------------------------------------------------------------------------
# Docker check
# --------------------------------------------------------------------------
check_docker() {
	if ! command -v docker >/dev/null 2>&1; then
		warn "Docker not found."
		local ans
		ans="$(read_tty "Install Docker via get.docker.com? [Y/n]: " "Y")"
		case "$ans" in
			y|Y|"")
				log "Installing Docker..."
				curl -fsSL https://get.docker.com | bash || die "Docker installation failed."
				log "Docker installed."
				;;
			*) die "Docker is required. Install manually: https://docs.docker.com/engine/install/";;
		esac
	fi
	if ! docker compose version >/dev/null 2>&1 && ! docker-compose version >/dev/null 2>&1; then
		die "docker compose not found. Install the Docker Compose plugin."
	fi
	docker info >/dev/null 2>&1 || die "Docker is not running or you lack permissions. Add yourself to the docker group or run as root."
}

# --------------------------------------------------------------------------
# sysctl kernel tuning (host-level, applied outside container)
# --------------------------------------------------------------------------
SYSCTL_FILE="/etc/sysctl.d/99-zanoza-docker.conf"

apply_sysctl_tuning() {
	ans="$(read_tty "Apply kernel network optimizations for high DNS load? [Y/n]: " "Y")"
	case "$ans" in
		y|Y|"") ;;
		*) log "Skipped kernel tuning."; return 0;;
	esac

	if ! command -v sysctl >/dev/null 2>&1; then
		warn "sysctl not found — skipping kernel tuning."
		return 0
	fi

	log "Applying kernel network optimizations → ${SYSCTL_FILE}"

	cat > "$SYSCTL_FILE" <<'SYSCTL_EOF'
# Zanoza Panel — kernel tuning for high-throughput DNS (UDP)
# Remove:  sudo rm /etc/sysctl.d/99-zanoza-docker.conf && sudo sysctl --system

# socket backlog
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384
net.core.optmem_max = 25165824

# buffer sizes
net.core.rmem_default = 262144
net.core.wmem_default = 262144
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432

# UDP buffer minimums
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.udp_mem = 65536 131072 262144

# short conntrack timeouts for UDP
net.netfilter.nf_conntrack_udp_timeout = 15
net.netfilter.nf_conntrack_udp_timeout_stream = 60

# ephemeral port range
net.ipv4.ip_local_port_range = 10240 65535
SYSCTL_EOF

	sysctl --system >/dev/null 2>&1 || {
		warn "Could not fully apply sysctl settings (some keys may not exist on this kernel)."
		warn "Partial settings were applied where possible — check ${SYSCTL_FILE}."
	}
	log "Kernel tuning applied."
}

# --------------------------------------------------------------------------
# Port 53 check & free
# --------------------------------------------------------------------------
who_on_53() {
	local pid="" pname=""
	if command -v ss >/dev/null 2>&1; then
		pid=$(ss -tulpn "( sport = :53 )" 2>/dev/null | grep -oP 'pid=\K\d+' | head -1) || true
	elif command -v fuser >/dev/null 2>&1; then
		pid=$(fuser 53/tcp 53/udp 2>/dev/null | tr -d ' ' | head -1) || true
	fi
	if [ -n "$pid" ] && [ -f "/proc/$pid/comm" ]; then
		pname=$(cat "/proc/$pid/comm")
		printf '%s:%s' "$pid" "$pname"
	fi
}

free_port_53() {
	local occupant pid pname
	occupant="$(who_on_53)" || true
	if [ -z "$occupant" ]; then
		log "Port 53 is free."
		return 0
	fi
	pid="${occupant%%:*}"; pname="${occupant##*:}"
	warn "Port 53 is in use by: $pname (PID $pid)"

	case "$pname" in
		systemd-resolve|systemd-resolved)
			log "Found systemd-resolved."
			ans="$(read_tty "Free port 53? Disable DNSStubListener in resolved [Y/n]: " "Y")"
			case "$ans" in y|Y)
				mkdir -p /etc/systemd/resolved.conf.d
				cat > /etc/systemd/resolved.conf.d/zanoza-docker.conf <<EOF
[Resolve]
DNSStubListener=no
EOF
				systemctl restart systemd-resolved 2>/dev/null || true
				sleep 1
				log "systemd-resolved restarted with DNSStubListener=no."
				occupant="$(who_on_53)" || true
				if [ -n "$occupant" ]; then
					warn "Port 53 is still in use ($occupant). A reboot or manual cleanup may be needed."
				fi
				;;
			*) die "Port 53 is in use. Free it manually and re-run the installer.";;
			esac
			;;
		*)
			warn "Process $pname (PID $pid) holds port 53."
			warn "Stop it (systemctl stop $pname, or kill $pid) and re-run the installer."
			ans="$(read_tty "Continue anyway? Port 53 is still in use [y/N]: " "N")"
			case "$ans" in y|Y) warn "Proceeding with occupied port 53 — the DNS server may fail to start.";;
			*) die "Installation cancelled.";;
			esac
			;;
	esac
}

# --------------------------------------------------------------------------
# Credentials
# --------------------------------------------------------------------------
setup_credentials() {
	local user pass salt hash

	ans="$(read_tty "Generate login and password automatically? [Y/n]: " "Y")"
	case "$ans" in
		y|Y|"")
			user="$(random_alnum 10)"
			pass="$(random_alnum 20)"
			;;
		*)
			user="$(read_tty "Login: " "admin")"
			pass="$(read_tty "Password: " "")"
			[ -n "$pass" ] || die "empty password is not allowed."
			;;
	esac

	mkdir -p "$CONFIG_DIR"
	salt="$(od -A n -t x1 -N 16 /dev/urandom | tr -d ' ')"
	hash="$(printf '%s' "${salt}:${pass}" | sha256sum | awk '{print $1}')"

	umask 077
	cat > "$CONFIG_DIR/panel.env" <<EOF
ZANOZA_PANEL_USER='${user}'
ZANOZA_PANEL_SALT='${salt}'
ZANOZA_PANEL_PASS_HASH='${hash}'
EOF

	ADMIN_USER="$user"
	ADMIN_PASS="$pass"
}

# --------------------------------------------------------------------------
# TLS (matches legacy installer: self-signed + auto-renew, Let's Encrypt, none)
# --------------------------------------------------------------------------
setup_tls() {
	log "TLS certificate setup"
	cat <<EOF

Choose a certificate option for the panel:
  1) Self-signed IP certificate, 6-day validity, auto-renewal (recommended for personal use)
  2) Let's Encrypt domain certificate (requires A record pointing to this server, e.g. panel.example.com)
  3) No TLS — panel listens on 127.0.0.1 only (access via nginx/SSH tunnel)
EOF
	local cert_choice
	cert_choice="$(read_tty "Option [1/2/3] (default 1): " "1")"

	case "$cert_choice" in
	2)
		setup_letsencrypt
		;;
	3)
		USE_TLS=0
		PANEL_ADDR="127.0.0.1"
		log "TLS disabled. Panel will listen on 127.0.0.1 only."
		;;
	*)
		setup_self_signed
		;;
	esac
}

setup_self_signed() {
	local ip
	ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
	[ -n "$ip" ] || ip="127.0.0.1"

	if generate_self_signed_cert "$CERT_FILE" "$KEY_FILE" "$ip" 6; then
		# Marker tells the container entrypoint to enable daily auto-renewal via crond.
		touch "$CERT_DIR/.renew-self-signed"
		USE_TLS=1
		CERT_HOST="$ip"
		log "Self-signed certificate generated for ${ip} (6-day validity, auto-renews daily)."
	else
		die "openssl failed to generate self-signed certificate."
	fi
}

setup_letsencrypt() {
	local domain
	domain="$(read_tty "Panel domain (A record must point to this server): " "")"
	[ -n "$domain" ] || die "domain is required for Let's Encrypt."

	log "Requesting Let's Encrypt certificate for ${domain}..."

	if issue_letsencrypt_cert "$domain" "$CERT_FILE" "$KEY_FILE" \
		"docker compose -f ${REPO_DIR}/docker-compose.yml restart"; then
		USE_TLS=1
		CERT_HOST="$domain"
		log "Let's Encrypt certificate installed for ${domain} (auto-renews via acme.sh)."
	else
		warn "Let's Encrypt issuance failed (check A record and that port 80 is free)."
		warn "Falling back to self-signed."
		setup_self_signed
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
main() {
	log "Zanoza Panel — Docker installer"
	log "================================"

	check_docker
	log "Docker found: $(docker --version)"

	free_port_53

	apply_sysctl_tuning

	setup_credentials

	setup_tls

	if [ ! -f "$ENV_FILE" ]; then
		cp "$ENV_EXAMPLE" "$ENV_FILE"
		log "Created .env from .env.example"
	fi

	if [ "${USE_TLS:-0}" -ne 1 ]; then
		sed -i 's|^ZANOZA_TLS_CERT=|#ZANOZA_TLS_CERT=|' "$ENV_FILE"
		sed -i 's|^ZANOZA_TLS_KEY=|#ZANOZA_TLS_KEY=|' "$ENV_FILE"
	fi

	if [ "${PANEL_ADDR:-}" = "127.0.0.1" ]; then
		sed -i "s|^ZANOZA_PANEL_ADDR=.*|ZANOZA_PANEL_ADDR=${PANEL_ADDR}|" "$ENV_FILE"
		log "Panel will listen on 127.0.0.1 (no TLS)"
	fi

	log "Building Docker image (first build may take a few minutes)..."
	docker compose -f "$REPO_DIR/docker-compose.yml" build

	log "Starting container..."
	docker compose -f "$REPO_DIR/docker-compose.yml" up -d

	sleep 2

	# Install the zanoza management CLI.
	ZANOZA_CLI="${REPO_DIR}/scripts/zanoza-docker"
	ZANOZA_TARGET="/usr/local/bin/zanoza"
	if [ -f "$ZANOZA_CLI" ]; then
		install -m 0755 "$ZANOZA_CLI" "$ZANOZA_TARGET"
		# Marker file so zanoza knows where the repo lives.
		mkdir -p /etc/zanoza-panel
		printf '%s' "$REPO_DIR" > /etc/zanoza-panel/.docker-install-dir
		log "Management CLI installed: zanoza"
	fi

	# Fix ownership: files created by root (via sudo) should belong to the real user.
	if [ -n "${SUDO_USER:-}" ]; then
		chown -R "$SUDO_USER":"$SUDO_USER" "$CONFIG_DIR" "$ENV_FILE"
		log "Permissions fixed for user $SUDO_USER"
	elif [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
		chown -R "$SUDO_UID":"$SUDO_GID" "$CONFIG_DIR" "$ENV_FILE"
		log "Permissions fixed for UID $SUDO_UID"
	fi

	PORT="${ZANOZA_PANEL_PORT:-8443}"
	[ -f "$ENV_FILE" ] && . "$ENV_FILE" 2>/dev/null || true
	PANEL_PATH="${ZANOZA_PANEL_PATH:-/admin}"
	SERVER_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
	SCHEME="http"; [ "${USE_TLS:-0}" -eq 1 ] && SCHEME="https"
	DISPLAY_HOST="$SERVER_IP"
	[ -n "${CERT_HOST:-}" ] && DISPLAY_HOST="$CERT_HOST"
	[ "${PANEL_ADDR:-}" = "127.0.0.1" ] && DISPLAY_HOST="127.0.0.1"
	URL="${SCHEME}://${DISPLAY_HOST}:${PORT}${PANEL_PATH}"

	cat <<EOF

============================================================
  Zanoza Panel is running in Docker.

  Panel URL    : ${URL}
  Login        : ${ADMIN_USER}
  Password     : ${ADMIN_PASS}

  Manage       : run  zanoza  (interactive menu)
============================================================
EOF
	# Warn for self-signed: marker file only exists for self-signed certs.
	[ -f "$CERT_DIR/.renew-self-signed" ] && warn "Using self-signed certificate — browsers will show a warning, this is normal."
	[ "${PANEL_ADDR:-}" = "127.0.0.1" ] && warn "Panel listens on 127.0.0.1 only — set up an nginx reverse proxy or SSH tunnel for external access."
	[ -f "$SYSCTL_FILE" ] && warn "Kernel tuning applied. To remove: sudo rm ${SYSCTL_FILE} && sudo sysctl --system"
}

main "$@"
