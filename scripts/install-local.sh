#!/usr/bin/env bash
# Install bifrost-http from a local checkout.
#
#   scripts/install-local.sh [--mode binary|service] [--prefix DIR]
#                            [--skip-ui] [--with-cli] [--force]
#
#   binary   (default) build bifrost-http (with UI) and install the binary
#                      into PREFIX (default: ~/.local/bin).
#   service            binary install, then install/(re)start the user
#                      systemd service via scripts/bifrost-service.sh.
#                      Service settings come from BIFROST_* env vars
#                      (see scripts/bifrost-service.sh --help).
#
# Run from anywhere; the script locates the repository through its own path.
set -euo pipefail

MODE=binary
PREFIX="$HOME/.local/bin"
SKIP_UI=0
WITH_CLI=0
FORCE=0

usage() {
	cat <<'EOF'
Install bifrost-http from this repository.

Usage: scripts/install-local.sh [options]

Options:
  --mode binary|service   Install mode (default: binary).
  --prefix DIR            Install directory (default: ~/.local/bin).
  --skip-ui               Skip the UI build (Go binary only).
  --with-cli              Also build and install the `bifrost` CLI.
  --force                 Rebuild even if tmp/ binaries exist; passed
                          through to bifrost-service.sh in service mode
                          (rebuild + restart).
  -h, --help              Show this help.

Modes:
  binary    Builds tmp/bifrost-http (with UI unless --skip-ui) and
            installs it as $PREFIX/bifrost-http. No service is touched.
  service   Binary install, then installs/(re)starts the user systemd
            service via scripts/bifrost-service.sh. Configure with
            BIFROST_DATA / BIFROST_HOST / BIFROST_PORT /
            BIFROST_LOG_LEVEL / BIFROST_LOG_STYLE env vars.
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
		--mode)
			MODE="${2:-}"
			shift 2
			;;
		--mode=*)
			MODE="${1#*=}"
			shift
			;;
		--prefix)
			PREFIX="${2:-}"
			[ -n "$PREFIX" ] || { printf 'install-local: --prefix needs a value\n' >&2; exit 1; }
			shift 2
			;;
		--prefix=*)
			PREFIX="${1#*=}"
			shift
			;;
		--skip-ui)
			SKIP_UI=1
			shift
			;;
		--with-cli)
			WITH_CLI=1
			shift
			;;
		--force)
			FORCE=1
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		*)
			printf 'install-local: unknown argument: %s\n\n' "$1" >&2
			usage >&2
			exit 2
			;;
	esac
done

case "$MODE" in
	binary | service) ;;
	*)
		printf 'install-local: --mode must be "binary" or "service", got "%s"\n' "$MODE" >&2
		exit 2
		;;
esac

step() { printf '\n▶ %s\n' "$1"; }
done_step() { printf '✓ %s\n' "$1"; }

command -v go >/dev/null 2>&1 || {
	printf 'install-local: go not found on PATH (see go.work; requires Go 1.27.0)\n' >&2
	exit 1
}

REPO_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
cd "$REPO_ROOT"

VERSION="$(git describe --tags --dirty --always 2>/dev/null || echo dev-build)"

need_build() {
	[ "$FORCE" -eq 1 ] && return 0
	[ -x "$REPO_ROOT/tmp/bifrost-http" ] || return 0
	return 1
}

if need_build; then
	if [ "$SKIP_UI" -eq 0 ]; then
		command -v node >/dev/null 2>&1 || {
			printf 'install-local: node not found on PATH; required for the UI build (or re-run with --skip-ui)\n' >&2
			exit 1
		}
		command -v npm >/dev/null 2>&1 || {
			printf 'install-local: npm not found on PATH; required for the UI build (or re-run with --skip-ui)\n' >&2
			exit 1
		}
		step "build bifrost-http (with UI)"
		# Makefile prepends `v` to VERSION for the ldflags version stamp.
		make build VERSION="${VERSION#v}"
	else
		step "build bifrost-http (Go only, UI skipped)"
		mkdir -p "$REPO_ROOT/tmp"
		(cd "$REPO_ROOT/transports/bifrost-http" && CGO_ENABLED=1 go build \
			-ldflags="-w -s -X main.Version=$VERSION" \
			-trimpath \
			-tags "sqlite_static" \
			-o ../../tmp/bifrost-http \
			.)
	fi
else
	step "reuse existing tmp/bifrost-http (use --force to rebuild)"
fi

BUILT="$REPO_ROOT/tmp/bifrost-http"
[ -x "$BUILT" ] || {
	printf 'install-local: build finished but %s is missing\n' "$BUILT" >&2
	exit 1
}

step "install binary into $PREFIX"
mkdir -p "$PREFIX"
# Remove first: an existing symlink at the target would make `install`
# overwrite the file it points at instead of replacing the link.
rm -f "$PREFIX/bifrost-http"
install -m 755 "$BUILT" "$PREFIX/bifrost-http"

if [ "$WITH_CLI" -eq 1 ]; then
	step "build + install bifrost CLI"
	make build-cli
	[ -x "$REPO_ROOT/tmp/bifrost" ] || {
		printf 'install-local: CLI build finished but tmp/bifrost is missing\n' >&2
		exit 1
	}
	rm -f "$PREFIX/bifrost"
	install -m 755 "$REPO_ROOT/tmp/bifrost" "$PREFIX/bifrost"
fi

case "$MODE" in
	service)
		step "install user systemd service"
		if [ "$FORCE" -eq 1 ]; then
			BIFROST_BIN="$PREFIX/bifrost-http" "$REPO_ROOT/scripts/bifrost-service.sh" install --force
		else
			BIFROST_BIN="$PREFIX/bifrost-http" "$REPO_ROOT/scripts/bifrost-service.sh" install
		fi
		;;
esac

step "verify"
if command -v bifrost-http >/dev/null 2>&1; then
	found=$(command -v bifrost-http)
	if [ "$found" != "$PREFIX/bifrost-http" ]; then
		printf 'install-local: note: "bifrost-http" on PATH resolves to %s, not %s (check PATH order)\n' "$found" "$PREFIX/bifrost-http" >&2
	fi
else
	printf 'install-local: note: %s is not on PATH\n' "$PREFIX/bifrost-http" >&2
fi
test -x "$PREFIX/bifrost-http" || {
	printf 'install-local: %s is not executable\n' "$PREFIX/bifrost-http" >&2
	exit 1
}

done_step "installed ($MODE) → $PREFIX/bifrost-http ($VERSION)"
