<div align="right">

[🇷🇺 Русский](README.md) · **🇬🇧 English**

</div>

# masterdns-zanoza-panel

Web panel and process manager for [MasterDnsVPN](https://github.com/masterking32/MasterDnsVPN) with [Zanoza (iOS)](https://github.com/palmbeachpete9/masterdns-zanoza-ios) support.

The admin creates "instances" (a **domain + encryption key** pair) and hands them to users: each instance shows as `domain + key` and can be copied as a `zanoza://` link for one-tap import into the Zanoza app.

---

![Panel — instances list](docs/dashboard.png)

![Create instance](docs/create-instance.png)

![Login](docs/login.png)

---

## Install

### Docker (recommended) — any Linux

```sh
# Docker will be auto-installed if missing.
# Run the installer:
curl -fsSL https://raw.githubusercontent.com/zuknes/masterdns-zanoza-panel/feature/docker-setup/scripts/docker-install.sh | sudo bash
```

The installer walks you through:

1. **Port 53** — checks if it's in use and offers to free it (disables `DNSStubListener` in systemd-resolved)
2. **Kernel tuning** — asks whether to apply sysctl optimizations for high DNS throughput (default: yes). Settings land in `/etc/sysctl.d/99-zanoza-docker.conf` and are easily removed: `sudo rm /etc/sysctl.d/99-zanoza-docker.conf && sudo sysctl --system`
3. **Login/password** — auto-generated (10 + 20 chars) or entered manually
4. **Certificate**:
   - **1) Self-signed IP cert** — 6-day validity, auto-renewed inside the container (crond)
   - **2) Let's Encrypt** — requires an A record `panel.example.com` → server IP
   - **3) No TLS** — panel listens on `127.0.0.1` only (expose via nginx / SSH tunnel)

The panel runs in `network_mode: host`, no need to publish ports. Auto-restart is enabled (`restart: unless-stopped`).

After installation, the `zanoza` CLI command is available:

```sh
zanoza              # interactive management menu (requires sudo)
sudo zanoza restart  # restart the panel
sudo zanoza logs     # view logs
sudo zanoza update   # update (git pull + rebuild)
sudo zanoza uninstall # remove the panel
```

Panel configuration — edit `.env` and restart with `zanoza restart`. Credentials are stored in `zanoza-config/panel.env` (hashed).

For local overrides (e.g. a different `restart` policy or extra volumes), create a `docker-compose.override.yml` — it is automatically picked up by Docker Compose and is git-ignored.

### Legacy — bare-metal (Ubuntu / Debian)

```sh
curl -fsSL https://raw.githubusercontent.com/zuknes/masterdns-zanoza-panel/feature/docker-setup/scripts/install.sh | sudo bash
```

The installer sets up Go, builds binaries from source, installs a systemd service and the `zanoza` CLI command.

> **Note:** The Docker version is simpler, requires no Go toolchain, isolates the panel, and works on any Linux distribution.

## Instance model (domains × keys)

A MasterDnsVPN server is a single process bound to **UDP :53** with **one** key and an array of domains. To hand out **different keys** per user, the panel ships a forked server with a **keyring** (`keyring.json`) that selects key(s) **by the queried domain** (the domain is cleartext, known before decryption):

- **One key per domain** → direct decrypt, **any** cipher works including **XOR** (fastest, zero overhead).
- **Several keys on one domain** → the server trials the ring; **AEAD** (ChaCha20 / AES-GCM) is required because only AEAD can tell the right key by its auth tag. Trial happens on that domain's inbound packets only; the hot key is moved to the front of the ring.

An instance's encryption method must **match** the method in the Zanoza app (the `zanoza://` link carries it automatically).

> **Important:** Every instance domain (`v.user1.example.com`, `v.user2.example.com`, …) must be delegated (NS) and/or point via an A record at **this panel server's IP**. Many domains may resolve to one IP.

## Repository layout

```
masterdns-zanoza-panel/
├── src/main.tsx                  # React UI (Vite + Tailwind + lucide)
├── index.html, vite.config.ts, tailwind.config.ts, package.json
├── cmd/zanoza-panel/             # Go panel backend (stdlib only)
│   ├── main.go                   #   HTTP/TLS, routing, API, embed web/dist
│   ├── config.go, auth.go        #   config + auth (cookie/basic)
│   ├── process.go                #   MasterDnsVPN supervisor + keyring.json
│   ├── zanozalink.go             #   zanoza:// link generation
│   └── web/dist/                 #   built frontend (embedded in the binary)
├── masterdns/                    # forked MasterDnsVPN server
│   └── internal/keyring/         #   per-domain keyring selection
├── scripts/
│   ├── docker-install.sh         #   Docker installer (any Linux)
│   ├── zanoza-docker             #   Docker management CLI command
│   └── install.sh                #   bare-metal installer (Ubuntu/Debian)
├── Dockerfile                    #   Docker image (Alpine, built from source)
├── docker-compose.yml            #   network_mode: host, restart: unless-stopped
├── docker-entrypoint.sh          #   entrypoint: config.json, crond for auto-renew
├── docker-renew-cert.sh          #   self-signed cert renewal (crond)
└── packaging/systemd/zanoza-panel.service
```

## Environment Variables

All variables are optional; the panel works without them using defaults.

| Variable | Purpose | Default |
|---|---|---|
| `ZANOZA_CONFIG` | Path to the panel JSON config | `/etc/zanoza-panel/config.json` |
| `ZANOZA_RUNTIME_DIR` | Directory for keyring.json + server_config.toml | `<configDir>/masterdns` |
| `ZANOZA_PANEL_ADDR` | HTTP listen address | from `config.json` |
| `ZANOZA_PANEL_PORT` | Panel port (1–65535) | from `config.json` |
| `ZANOZA_PANEL_PATH` | Admin URL path (e.g. `/secret`) | from `config.json` |
| `ZANOZA_TLS_CERT` / `ZANOZA_TLS_KEY` | TLS certificate and key paths | from `config.json` |
| `ZANOZA_NAME` | Server name (shown in UI) | from `config.json` |
| `ZANOZA_USER` / `ZANOZA_PASSWORD` | Auto-create admin on first run | — (first setup only) |
| `ZANOZA_MASTERDNS_BIN` | Path to the MasterDnsVPN binary | `/usr/local/bin/masterdns-server` |
| `ZANOZA_DNS_HOST` | DNS server UDP listen address | `0.0.0.0` |
| `ZANOZA_DNS_PORT` | DNS server UDP port (1–65535) | `53` |
| `ZANOZA_DNS_UPSTREAM` | JSON array of upstream resolvers | `["1.1.1.1:53", "1.0.0.1:53"]` |

In the Docker version, variables are set in the `.env` file (copied from `.env.example` during install).

## Build from source

```sh
# tools (once)
go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@latest
go install mvdan.cc/gofumpt@latest

# frontend (needs node)
npm install && npm run build

# everything via Makefile
make fmt      # format with gofumpt
make lint     # golangci-lint
make test     # tests with -race
make build    # compile binaries
make check    # all at once (CI)
```

## Credits

- Protocol and server: [MasterDnsVPN by MasterkinG32](https://github.com/masterking32/MasterDnsVPN)
- UI and structure: [olcrtc-manager-panel](https://github.com/BigDaddy3334/olcrtc-manager-panel)
- Installer / CLI style: [3x-ui](https://github.com/MHSanaei/3x-ui)
- Client app: [Zanoza (iOS)](https://github.com/palmbeachpete9/masterdns-zanoza-ios)
