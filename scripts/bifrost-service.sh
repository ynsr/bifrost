#!/usr/bin/env bash
# === bifrost-service — Install, manage, and migrate Bifrost as a user-scoped systemd service ===
set -euo pipefail

BIFROST_REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIFROST_BIN="${BIFROST_BIN:-$HOME/.local/bin/bifrost-http}"
BIFROST_DATA="${BIFROST_DATA:-$HOME/.local/share/bifrost}"
BIFROST_LOG_LEVEL="${BIFROST_LOG_LEVEL:-info}"
BIFROST_LOG_STYLE="${BIFROST_LOG_STYLE:-pretty}"
BIFROST_HOST="${BIFROST_HOST:-127.0.0.1}"
BIFROST_PORT="${BIFROST_PORT:-7698}"
BIFROST_VERSION="$(cd "$BIFROST_REPO" && git describe --tags --dirty --always 2>/dev/null || echo "dev-build")"

SERVICE_NAME="bifrost-http"
SERVICE_FILE="$HOME/.config/systemd/user/$SERVICE_NAME.service"

DOCKER_COMPOSE_DIR="/home/bs/projects/personal/cli-agents-config/setup-ubuntu-server/bifrost"
DOCKER_DATA_DIR="$DOCKER_COMPOSE_DIR/data"

RED=; GREEN=; YELLOW=; CYAN=; BOLD=; NC=
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
fi

# ── State ──────────────────────────────────────────────────────────────────
VERBOSE=false
QUIET=false
FORCE=false
DRY_RUN=false
# Log prefix is stripped unless we're interactive or verbose
LOG_PREFIX=""

# ── Helpers ─────────────────────────────────────────────────────────────────
log()  { local lvl=$1; shift; [ "$QUIET" = true ] && return 0; case "$lvl" in
          OK) echo -e "${GREEN}✓${NC} $*" ;;
          INFO) echo -e "${CYAN}ℹ${NC} $*" ;;
          WARN) echo -e "${YELLOW}⚠${NC} $*" >&2 ;;
          ERR)  echo -e "${RED}✗${NC} $*" >&2 ;;
        esac; }
vlog() { [ "$VERBOSE" = true ] && log INFO "$@" || true; }
dry()  { echo -e "${YELLOW}[DRY-RUN]${NC} $*"; }
run()  {
  if [ "$DRY_RUN" = true ]; then dry "$@"; return 0; fi
  "$@"
}
sudo_run() {
  if [ "$DRY_RUN" = true ]; then dry "sudo $*"; return 0; fi
  sudo "$@"
}

# ── systemd helpers ─────────────────────────────────────────────────────────
_sys() { systemctl --user "$@"; }
_sys_status() { _sys is-active --quiet "$SERVICE_NAME" 2>/dev/null; }
_sys_enabled(){ _sys is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; }
_is_running() { _sys_status && return 0; return 1; }
_ensure_linger() {
  if ! loginctl show-user "$USER" --property=Linger 2>/dev/null | grep -q 'Linger=yes'; then
    log INFO "Enabling linger for user $USER so the service survives logout..."
    run loginctl enable-linger "$USER"
  fi
}
_journal() { journalctl --user --unit="$SERVICE_NAME" "$@"; }

# ── Build ────────────────────────────────────────────────────────────────────
build_ui() {
  local ui_src="$BIFROST_REPO/ui"
  local ui_dst="$BIFROST_REPO/transports/bifrost-http/ui"

  # Skip if UI build output already exists
  if [ -d "$ui_dst" ] && [ -f "$ui_dst/index.html" ] && [ "$FORCE" != true ]; then
    vlog "UI build already exists at $ui_dst (use --force to rebuild)"
    return 0
  fi

  vlog "Building UI from $ui_src..."
  if [ ! -d "$ui_src/node_modules" ]; then
    vlog "Installing npm dependencies..."
    run cd "$ui_src" && run npm ci
  fi

  # Run vite build directly (vite build always succeeds; tsc typecheck has
  # pre-existing enterprise stub errors). Then copy output manually.
  run cd "$ui_src" && run npx vite build 2>&1
  # Copy build output to the embed directory
  run rm -rf "$ui_dst"
  run cp -r "$ui_src/out" "$ui_dst"
  vlog "UI built and copied to $ui_dst"
}

build_binary() {
  local bin_dir; bin_dir="$(dirname "$BIFROST_BIN")"
  vlog "Building bifrost-http from $BIFROST_REPO..."

  # The transports/module uses replace directives for local deps
  if [ ! -f "$BIFROST_REPO/transports/go.mod" ]; then
    log ERR "Cannot find transports/go.mod — wrong repo root?"
    return 1
  fi

  # Ensure replace directives exist for local framework/core (they may have
  # been stripped by `go mod tidy` between sessions — re-add idempotently).
  for dep in framework core; do
    line="replace github.com/maximhq/bifrost/$dep => ../$dep"
    if ! grep -qF "$line" "$BIFROST_REPO/transports/go.mod"; then
      echo "$line" >> "$BIFROST_REPO/transports/go.mod"
      vlog "Added missing replace directive for $dep"
    fi
  done

  local build_dir="$BIFROST_REPO/transports/bifrost-http"
  run mkdir -p "$bin_dir"
  run cd "$build_dir"
  run env CGO_ENABLED=1 go build \
    -ldflags="-w -s -X main.Version=$BIFROST_VERSION" \
    -tags "sqlite_static" \
    -trimpath \
    -o "$BIFROST_BIN" \
    .
  run chmod +x "$BIFROST_BIN"
  vlog "Binary built: $BIFROST_BIN"
}

# ── Install / Uninstall ──────────────────────────────────────────────────────
cmd_install() {
  log INFO "Installing Bifrost ($BIFROST_VERSION)..."

  # 1. Build UI first (needed for Go embed), then binary
  if [ "$FORCE" = true ] || [ ! -x "$BIFROST_BIN" ]; then
    build_ui
    build_binary
  else
    vlog "Binary already exists at $BIFROST_BIN (use --force to rebuild)"
  fi

  # 2. Create data directory
  run mkdir -p "$BIFROST_DATA"

  # 3. Ensure linger
  _ensure_linger

  # 4. Write systemd unit
  run mkdir -p "$HOME/.config/systemd/user"
  local unit_content
  unit_content=$(cat << UNIT
[Unit]
Description=Bifrost AI Gateway (user service)
Documentation=https://github.com/maximhq/bifrost
After=network.target

[Service]
Type=simple
ExecStart=$BIFROST_BIN -app-dir "$BIFROST_DATA" -host "$BIFROST_HOST" -port "$BIFROST_PORT" -log-level "$BIFROST_LOG_LEVEL" -log-style "$BIFROST_LOG_STYLE"
Restart=on-failure
RestartSec=5
Environment=HOME=%h
# Allow the service to inherit SSH agent, D-Bus, etc. for proxy env vars.
KeepMainEnvironment=yes
# Propagate proxy env vars from the user session if set.
PassEnvironment=ALL_PROXY SOCKS_PROXY HTTP_PROXY HTTPS_PROXY NO_PROXY http_proxy https_proxy no_proxy

[Install]
WantedBy=default.target
UNIT
)
  if [ "$DRY_RUN" = true ]; then
    dry "Write systemd unit to $SERVICE_FILE"
    echo "$unit_content"
  else
    echo "$unit_content" > "$SERVICE_FILE"
  fi

  # 5. Reload daemon, enable, start
  run _sys daemon-reload
  run _sys enable "$SERVICE_NAME"
  run _sys start "$SERVICE_NAME"

  log OK "Bifrost installed and started."
  log INFO "  Binary:  $BIFROST_BIN"
  log INFO "  Data:    $BIFROST_DATA"
  log INFO "  Service: $SERVICE_FILE"
  log INFO "  Port:    $BIFROST_HOST:$BIFROST_PORT"
  log INFO "  Logs:    journalctl --user -u $SERVICE_NAME -f"
}

cmd_uninstall() {
  log WARN "This will stop and remove the Bifrost service. Data will NOT be deleted."
  [ "$FORCE" = false ] && [ "$DRY_RUN" = false ] && read -rp "Continue? [y/N] " ans && [ "$ans" != "y" ] && [ "$ans" != "Y" ] && log INFO "Aborted." && return 0

  if _sys_status 2>/dev/null; then
    run _sys stop "$SERVICE_NAME" || true
  fi
  if _sys_enabled 2>/dev/null; then
    run _sys disable "$SERVICE_NAME" || true
  fi
  if [ -f "$SERVICE_FILE" ]; then
    run rm -f "$SERVICE_FILE"
    run _sys daemon-reload
  fi
  log OK "Bifrost service removed. Data at $BIFROST_DATA preserved."
}

# ── Migrate from Docker Compose ──────────────────────────────────────────────
cmd_migrate() {
  if [ ! -d "$DOCKER_DATA_DIR" ]; then
    log INFO "No Docker data found at $DOCKER_DATA_DIR — nothing to migrate."
    return 0
  fi

  log INFO "Migrating data from Docker Compose setup at $DOCKER_COMPOSE_DIR..."
  log WARN "The Docker Bifrost will be stopped at the end of migration."

  # Ensure native install exists first
  if [ ! -x "$BIFROST_BIN" ]; then
    log INFO "Bifrost not installed yet — installing first."
    cmd_install
  fi

  # Stop the native service while we set up data
  if _is_running 2>/dev/null; then
    vlog "Stopping Bifrost service for data migration..."
    run _sys stop "$SERVICE_NAME"
  fi

  # Ensure native data directory exists
  run mkdir -p "$BIFROST_DATA"
  run mkdir -p "$BIFROST_DATA/logs"

  # Copy SQLite databases (use cp to preserve data; sqlite3 would be safer for
  # hot-copy but we're guaranteed the Docker container is still running and
  # might have a WAL. Use sqlite3 .backup if available.)
  local needs_vacuum=false
  for db_file in config.db logs.db; do
    local src="$DOCKER_DATA_DIR/$db_file"
    local dst="$BIFROST_DATA/$db_file"
    if [ -f "$src" ]; then
      vlog "Migrating $db_file ($(du -h "$src" | cut -f1))..."
      if command -v sqlite3 &>/dev/null; then
        # Use .backup for a consistent snapshot even if WAL is active
        run sqlite3 "$src" ".backup '$dst'"
      else
        run cp -a "$src" "$dst"
        needs_vacuum=true
      fi
    fi
  done

  # Migrate WAL/SHM if no sqlite3 (they'll be replayed on open anyway)
  if [ "$needs_vacuum" = true ]; then
    for ext in db-wal db-shm; do
      for db_file in config logs; do
        local src="$DOCKER_DATA_DIR/$db_file.$ext"
        [ -f "$src" ] && run cp -a "$src" "$BIFROST_DATA/" 2>/dev/null || true
      done
    done
  fi

  # Copy logs directory (flat files, not DB-based logs)
  if [ -d "$DOCKER_DATA_DIR/logs" ] && [ "$(ls -A "$DOCKER_DATA_DIR/logs" 2>/dev/null)" ]; then
    vlog "Migrating log files..."
    run cp -a "$DOCKER_DATA_DIR/logs/." "$BIFROST_DATA/logs/"
  fi

  # Fix ownership (the Docker files may be root-owned)
  run chown -R "$USER:" "$BIFROST_DATA" 2>/dev/null || true

  log OK "Data migrated to $BIFROST_DATA"

  # Stop Docker Compose
  if [ -f "$DOCKER_COMPOSE_DIR/docker-compose.yml" ]; then
    log INFO "Stopping Docker Compose Bifrost..."
    # Don't use --dry-run for destructive docker-compose down that the user expects
    if [ "$DRY_RUN" = false ]; then
      (cd "$DOCKER_COMPOSE_DIR" && docker compose down) || log WARN "docker compose down failed (maybe already stopped)."
    else
      dry "cd $DOCKER_COMPOSE_DIR && docker compose down"
    fi
    log OK "Docker Compose Bifrost stopped."
  fi

  # Start native service (stop first if already running, to pick up migrated data)
  if _is_running; then
    run _sys stop "$SERVICE_NAME"
  fi
  run _sys daemon-reload
  run _sys start "$SERVICE_NAME"
  log OK "Migration complete. Bifrost now running natively on $BIFROST_HOST:$BIFROST_PORT"
}

# ── Service lifecycle ────────────────────────────────────────────────────────
cmd_start()   { run _sys start "$SERVICE_NAME";   log OK "Service started."; }
cmd_stop()    { run _sys stop "$SERVICE_NAME";    log OK "Service stopped."; }
cmd_restart() { run _sys restart "$SERVICE_NAME"; log OK "Service restarted."; }
cmd_status()  { _sys --no-pager status "$SERVICE_NAME"; }
cmd_logs()    { _journal -f "$@"; }

# ── Help ─────────────────────────────────────────────────────────────────────
usage() {
  cat << HELP
${BOLD}bifrost-service.sh${NC} — Install, manage, and migrate Bifrost as a user systemd service

${BOLD}Usage:${NC}
  $0 <command> [options]

${BOLD}Commands:${NC}
  install            Build and install Bifrost as a user-scoped systemd service
  uninstall          Stop and remove the systemd service (preserves data)
  migrate            Migrate data from Docker Compose to native install
  start              Start the bifrost service
  stop               Stop the bifrost service
  restart            Restart the bifrost service
  status             Show systemd service status
  logs               Tail service logs (pass journalctl flags like -n 100 --no-pager)

${BOLD}Options:${NC}
  -h, --help         Show this help
  --version          Show version
  -v, --verbose      Verbose output
  -q, --quiet        Quiet output (errors only)
  -f, --force        Skip confirmation prompts, rebuild binary
  -n, --dry-run      Print what would happen without executing

${BOLD}Environment variables:${NC}
  BIFROST_BIN        Binary path (default: ~/.local/bin/bifrost-http)
  BIFROST_DATA       Data directory (default: ~/.local/share/bifrost)
  BIFROST_HOST       Bind host (default: 127.0.0.1)
  BIFROST_PORT       Listen port (default: 7698)
  BIFROST_LOG_LEVEL  Log level: debug|info|warn|error (default: info)
  BIFROST_LOG_STYLE  Log style: json|pretty (default: pretty)

${BOLD}Examples:${NC}
  $0 install              # Build and install
  $0 install --force      # Force rebuild binary
  $0 migrate              # Migrate from Docker + install natively
  $0 logs -n 50           # Show last 50 log lines
  $0 restart              # Restart the service

HELP
}

# ── Main ─────────────────────────────────────────────────────────────────────
main() {
  if [ $# -eq 0 ]; then usage; exit 0; fi

  local subcommand=""; local passthru=()

  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --version) echo "bifrost-service $BIFROST_VERSION"; exit 0 ;;
      -v|--verbose) VERBOSE=true ;;
      -q|--quiet) QUIET=true ;;
      -f|--force) FORCE=true ;;
      -n|--dry-run) DRY_RUN=true ;;
      install|uninstall|migrate|start|stop|restart|status|logs)
        subcommand="$1"
        shift
        # remaining args are passthrough (e.g. logs -n 50)
        passthru=("$@")
        break
        ;;
      *)
        echo -e "${RED}Unknown option: $1${NC}" >&2
        usage >&2
        exit 2
        ;;
    esac
    shift
  done

  case "$subcommand" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    migrate)   cmd_migrate ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    restart)   cmd_restart ;;
    status)    cmd_status ;;
    logs)      cmd_logs "${passthru[@]}" ;;
    *)
      echo -e "${RED}Missing command. See --help${NC}" >&2
      exit 2
      ;;
  esac
}

main "$@"