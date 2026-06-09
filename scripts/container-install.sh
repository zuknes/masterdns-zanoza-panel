#!/usr/bin/env bash
# ==============================================================================
# Zanoza Panel — Container installer (any Linux, run as root).
#   curl -fsSL https://raw.githubusercontent.com/zuknes/masterdns-zanoza-panel/feature/docker-installer/scripts/container-install.sh | sudo bash
#
# Automatically picks Docker or Podman (with Quadlet).
# ==============================================================================
set -euo pipefail

REPO_URL="https://github.com/zuknes/masterdns-zanoza-panel.git"
# TODO(merge): change default branch to "main" when merging to main.
REF="${ZANOZA_REF:-feature/docker-installer}"
REPO_DEFAULT_DIR="/opt/zanoza-panel"
INSTALL_CONF="/etc/zanoza-panel/install.conf"

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

# ==========================================================================
# Distro guessing (used when nothing is installed — what to offer).
# ==========================================================================
guess_distro() {
	if [ -f /etc/os-release ]; then
		# shellcheck source=/dev/null
		. /etc/os-release
		case "${ID:-}" in
			debian)         echo "debian" ;;
			rhel|rocky|almalinux|centos|fedora) echo "rhel" ;;
			ubuntu)         echo "ubuntu" ;;
			*)              echo "${ID:-unknown}" ;;
		esac
	else
		echo "unknown"
	fi
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
		git clone --depth 1 --branch "$REF" "$REPO_URL" "$REPO_DIR" 2>/dev/null || \
		git clone --depth 1 "$REPO_URL" "$REPO_DIR" || {
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

# ==========================================================================
# Container runtime detection & installation
# ==========================================================================

install_docker() {
	log "Installing Docker via get.docker.com..."
	curl -fsSL https://get.docker.com | bash || die "Docker installation failed."
	if ! docker compose version >/dev/null 2>&1 && ! docker-compose version >/dev/null 2>&1; then
		warn "docker compose plugin not found — you may need to install it manually."
	fi
	log "Docker installed: $(docker --version 2>/dev/null || true)"
	CONTAINER_RUNTIME=docker
	COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
}

install_podman() {
	local pkg
	pkg="$(detect_pkg_manager)"
	log "Installing Podman..."
	pkg_install "$pkg" podman || die "Podman installation failed."
	log "Podman installed: $(podman --version 2>/dev/null || true)"
	CONTAINER_RUNTIME=podman
	INSTALL_METHOD=quadlet
	UNIT_NAME=zanoza-panel
}

offer_container_runtime() {
	local distro ans
	distro="$(guess_distro)"

	log "No container runtime detected."

	case "$distro" in
		debian)
			warn "Debian 12 ships Podman 4.3 (no Quadlet support)."
			log "Docker is recommended for Debian."
			ans="$(read_tty "Install Docker? [Y/n]: " "Y")"
			case "$ans" in y|Y|"") install_docker ;; *) die "Installation cancelled." ;; esac
			;;
		rhel|rocky|almalinux|centos|fedora)
			log "Podman is native to RHEL systems and works well with Quadlet."
			ans="$(read_tty "Install Podman? [Y/n]: " "Y")"
			case "$ans" in y|Y|"") install_podman ;; *) die "Installation cancelled." ;; esac
			;;
		ubuntu)
			log "Ubuntu 24.04+ ships Podman 4.9 with Quadlet support."
			ans="$(read_tty "Install Podman? [Y/n] (or 'd' for Docker): " "Y")"
			case "$ans" in
				d|D|docker) install_docker ;;
				y|Y|"") install_podman ;;
				*) die "Installation cancelled." ;;
			esac
			;;
		*)
			ans="$(read_tty "Install Docker? [Y/n] (or 'p' for Podman): " "Y")"
			case "$ans" in
				p|P|podman) install_podman ;;
				y|Y|"") install_docker ;;
				*) die "Installation cancelled." ;;
			esac
			;;
	esac
}

check_container_runtime() {
	# Priority 1: Docker already works — use it (best compose experience).
	if has_docker; then
		CONTAINER_RUNTIME=docker
		COMPOSE_FILE="$REPO_DIR/docker-compose.yml"
		log "Docker detected: $(docker --version 2>/dev/null || true)"
		return 0
	fi

	# Priority 2: Podman available.
	if has_podman; then
		local podman_ver
		podman_ver="$(get_podman_version)"

		if [ -n "$podman_ver" ] && version_gte "$podman_ver" "4.4"; then
			CONTAINER_RUNTIME=podman
			INSTALL_METHOD=quadlet
			UNIT_NAME=zanoza-panel
			PODMAN_VERSION="$podman_ver"
			log "Podman ${podman_ver} detected — using Quadlet."
			return 0
		else
			warn "Podman ${podman_ver:-?} does not support Quadlet (needs ≥ 4.4)."
			cat <<EOF

Options:
  1) Use Podman ${podman_ver:-?} with podman generate systemd
  2) Install Docker instead (via get.docker.com)
EOF
			ans="$(read_tty "Choose [1/2] (default 1): " "1")"
			case "$ans" in
				2) install_docker ;;
				*)
					CONTAINER_RUNTIME=podman
					INSTALL_METHOD=generate-systemd
					UNIT_NAME=container-zanoza-panel
					PODMAN_VERSION="$podman_ver"
					log "Using Podman ${podman_ver:-?} with generate-systemd."
					;;
			esac
			return 0
		fi
	fi

	# Priority 3: Nothing installed — offer based on distro.
	offer_container_runtime
}

# ==========================================================================
# Podman-specific setup helpers
# ==========================================================================

# Generate a Quadlet .container file at /etc/containers/systemd/.
write_quadlet_file() {
	local vol_flag
	vol_flag="$(selinux_volume_flag)"
	mkdir -p /etc/containers/systemd
	cat > /etc/containers/systemd/zanoza-panel.container <<QUADLET
[Container]
Image=localhost/zanoza-panel:latest
Network=host
EnvironmentFile=${REPO_DIR}/.env
Environment=ZANOZA_MASTERDNS_BIN=/usr/local/bin/masterdns-server
Volume=${REPO_DIR}/zanoza-config:/etc/zanoza-panel${vol_flag}
HealthCmd=curl -fksS --connect-timeout 5 https://127.0.0.1:\${ZANOZA_PANEL_PORT:-8443}\${ZANOZA_PANEL_PATH:-/admin} || curl -fksS --connect-timeout 5 http://127.0.0.1:\${ZANOZA_PANEL_PORT:-8443}\${ZANOZA_PANEL_PATH:-/admin} || exit 1
HealthInterval=30s
HealthTimeout=10s
HealthRetries=3
HealthStartPeriod=10s

[Service]
Restart=always
StartLimitBurst=0

[Install]
WantedBy=multi-user.target
QUADLET
	chmod 644 /etc/containers/systemd/zanoza-panel.container
	log "Quadlet file written to /etc/containers/systemd/zanoza-panel.container"
}

# get_reload_cmd() is provided by zanoza-common.sh

# Podman < 4.4: use podman run + podman generate systemd.
setup_podman_generate_systemd() {
	local vol_flag
	vol_flag="$(selinux_volume_flag)"

	log "Starting container with podman run..."
	podman run -d --name zanoza-panel \
		--network host \
		--env-file "$ENV_FILE" \
		-e ZANOZA_MASTERDNS_BIN=/usr/local/bin/masterdns-server \
		-v "${REPO_DIR}/zanoza-config:/etc/zanoza-panel${vol_flag}" \
		--health-cmd 'curl -fksS --connect-timeout 5 https://127.0.0.1:${ZANOZA_PANEL_PORT:-8443}${ZANOZA_PANEL_PATH:-/admin} || curl -fksS --connect-timeout 5 http://127.0.0.1:${ZANOZA_PANEL_PORT:-8443}${ZANOZA_PANEL_PATH:-/admin} || exit 1' \
		--health-interval 30s \
		--health-timeout 10s \
		--health-retries 3 \
		--health-start-period 10s \
		zanoza-panel

	log "Generating systemd unit..."
	podman generate systemd --name zanoza-panel --files --new

	# Move generated unit to systemd path.
	if [ -f container-zanoza-panel.service ]; then
		mv container-zanoza-panel.service /etc/systemd/system/
	else
		# podman generate systemd sometimes creates files in /tmp or cwd.
		# Look for any container-zanoza-panel.service file.
		local genfile
		genfile="$(find /tmp /run -name 'container-zanoza-panel.service' -maxdepth 3 2>/dev/null | head -1)"
		if [ -n "$genfile" ]; then
			cp "$genfile" /etc/systemd/system/container-zanoza-panel.service
		else
			die "podman generate systemd did not produce a unit file."
		fi
	fi

	systemctl daemon-reload
	systemctl enable --now container-zanoza-panel
	log "Systemd unit installed: container-zanoza-panel.service"
}

# Write install.conf — single source of truth for the CLI.
write_install_conf() {
	mkdir -p /etc/zanoza-panel
	umask 022
	cat > "$INSTALL_CONF" <<CONF
CONTAINER_RUNTIME=${CONTAINER_RUNTIME}
REPO_DIR=${REPO_DIR}
CONF

	case "${CONTAINER_RUNTIME}" in
		podman)
			cat >> "$INSTALL_CONF" <<CONF
INSTALL_METHOD=${INSTALL_METHOD:-quadlet}
UNIT_NAME=${UNIT_NAME:-zanoza-panel}
PODMAN_VERSION=${PODMAN_VERSION:-unknown}
CONF
			;;
	esac

	log "Install config written to ${INSTALL_CONF}"
}

# Build and start the container for the current runtime.
build_and_start() {
	case "${CONTAINER_RUNTIME}" in
		docker)
			log "Building Docker image (first build may take a few minutes)..."
			docker compose -f "${COMPOSE_FILE}" build
			log "Starting container..."
			docker compose -f "${COMPOSE_FILE}" up -d
			;;
		podman)
			log "Building Podman image..."
			( cd "$REPO_DIR" && podman build -t zanoza-panel . )

			case "${INSTALL_METHOD:-quadlet}" in
				quadlet)
					write_quadlet_file
					systemctl daemon-reload
					systemctl enable --now zanoza-panel
					log "Container started via systemd (zanoza-panel.service)"
					;;
				generate-systemd)
					setup_podman_generate_systemd
					;;
				*) die "Unknown INSTALL_METHOD: ${INSTALL_METHOD}" ;;
			esac
			;;
		*) die "Unknown CONTAINER_RUNTIME: ${CONTAINER_RUNTIME}" ;;
	esac
}



# ==========================================================================
# sysctl kernel tuning (host-level, applied outside container)
# ==========================================================================
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
		warn "sysctl --system failed — kernel tuning may not have been applied."
	}
	log "Kernel tuning applied."
}

# ==========================================================================
# Port 53 check & free
# ==========================================================================
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
			ans="$(read_tty "Free port 53? This will disable DNSStubListener in resolved [y/N]: " "N")"
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

# ==========================================================================
# Credentials
# ==========================================================================
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

	local old_umask
	old_umask="$(umask)"
	umask 077
	cat > "$CONFIG_DIR/panel.env" <<EOF
ZANOZA_PANEL_USER='${user}'
ZANOZA_PANEL_SALT='${salt}'
ZANOZA_PANEL_PASS_HASH='${hash}'
EOF
	umask "$old_umask"

	ADMIN_USER="$user"
	ADMIN_PASS="$pass"
}

# ==========================================================================
# TLS (matches legacy installer: self-signed + auto-renew, Let's Encrypt, none)
# ==========================================================================
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
	# Get first non-Docker-bridge IP, falling back to 127.0.0.1
	ip="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -v '^172\.17\.' | grep -v '^172\.1[89]\.' | grep -v '^172\.2[0-9]\.' | grep -v '^172\.3[01]\.' | head -1)"
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
	local domain reload_cmd
	domain="$(read_tty "Panel domain (A record must point to this server): " "")"
	[ -n "$domain" ] || die "domain is required for Let's Encrypt."

	reload_cmd="$(get_reload_cmd)"
	log "Requesting Let's Encrypt certificate for ${domain}..."

	if issue_letsencrypt_cert "$domain" "$CERT_FILE" "$KEY_FILE" "$reload_cmd"; then
		USE_TLS=1
		CERT_HOST="$domain"
		log "Let's Encrypt certificate installed for ${domain} (auto-renews via acme.sh)."
	else
		warn "Let's Encrypt issuance failed (check A record and that port 80 is free)."
		warn "Falling back to self-signed."
		setup_self_signed
	fi
}

# ==========================================================================
# Main
# ==========================================================================
main() {
	log "Zanoza Panel — Container installer"
	log "===================================="

	check_container_runtime

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

	build_and_start

	sleep 2

	# Install the zanoza management CLI and write install config.
	ZANOZA_CLI="${REPO_DIR}/scripts/zanoza-container"
	ZANOZA_TARGET="/usr/local/bin/zanoza"
	if [ -f "$ZANOZA_CLI" ]; then
		# Warn if zanoza already exists from a different install.
		if [ -f "$ZANOZA_TARGET" ]; then
			warn "/usr/local/bin/zanoza already exists — overwriting."
		fi
		install -m 0755 "$ZANOZA_CLI" "$ZANOZA_TARGET"
		log "Management CLI installed: zanoza"
	fi
	write_install_conf

	# Fix ownership: files created by root (via sudo) should belong to the real user.
	if [ -n "${SUDO_USER:-}" ]; then
		chown -R "$SUDO_USER":"$SUDO_USER" "$CONFIG_DIR" "$ENV_FILE"
		log "Permissions fixed for user $SUDO_USER"
	elif [ -n "${SUDO_UID:-}" ] && [ -n "${SUDO_GID:-}" ]; then
		chown -R "$SUDO_UID":"$SUDO_GID" "$CONFIG_DIR" "$ENV_FILE"
		log "Permissions fixed for UID $SUDO_UID"
	fi

	PORT="${ZANOZA_PANEL_PORT:-8443}"
	# shellcheck source=/dev/null
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
  Zanoza Panel is running in ${CONTAINER_RUNTIME}.

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
