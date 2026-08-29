#!/usr/bin/env bash
#
# docker-push.sh — Build and push the yooresh/bifrost Docker image
#
# Usage:
#   ./scripts/docker-push.sh              # build + push (prompts before push)
#   ./scripts/docker-push.sh --push       # build + push without prompt
#   ./scripts/docker-push.sh --skip-push  # build only, no push
#   ./scripts/docker-push.sh --tag v1.0.0 # tag with a specific version
#   ./scripts/docker-push.sh --help       # show this help
#   ./scripts/docker-push.sh --goproxy https://my-proxy:8080  # custom Go module proxy
#
# Environment:
#   GOPROXY       If set, used as the Go module proxy (overridden by --goproxy)
#   HTTP_PROXY    If set, passed as build-arg for HTTP forward proxy (e.g. mitmproxy, Squid)
#   HTTPS_PROXY   If set, passed as build-arg for HTTPS forward proxy
#   NO_PROXY      If set, passed as build-arg for proxy exclusion
#
# Prerequisites:
#   - Docker installed and running
#   - Logged into Docker Hub: `docker login`
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ------------------------------------------------------------------
# Defaults
# ------------------------------------------------------------------
IMAGE_NAME="yooresh/bifrost"
PUSH_IMAGE=false
SKIP_PUSH=false
VERSION=""
GOPROXY="${GOPROXY:-}"

# ------------------------------------------------------------------
# Parse arguments
# ------------------------------------------------------------------
usage() {
    # Skip shebang (line 1), extract comment block (lines starting with #)
    tail -n +2 "${BASH_SOURCE[0]}" | sed -n '/^#/s/^# \?//p'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --push)     PUSH_IMAGE=true ;;
        --skip-push) SKIP_PUSH=true ;;
        --tag)      VERSION="$2"; shift ;;
        --goproxy)  GOPROXY="$2"; shift ;;
        --help)     usage ;;
        *)          echo "Unknown option: $1"; usage ;;
    esac
    shift
done

# ------------------------------------------------------------------
# Determine tags
# ------------------------------------------------------------------
GIT_SHA="$(cd "$PROJECT_ROOT" && git rev-parse --short HEAD 2>/dev/null || echo 'unknown')"

if [[ -z "$VERSION" ]]; then
    # Try to derive version from git tag, then fall back to branch name + sha
    VERSION="$(cd "$PROJECT_ROOT" && git describe --tags --abbrev=0 2>/dev/null || echo 'latest')"
fi

TAGS=()
TAGS+=("$IMAGE_NAME:$VERSION")
TAGS+=("$IMAGE_NAME:$GIT_SHA")

# If this looks like a semver release tag, also tag as latest
if [[ "$VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+ ]]; then
    TAGS+=("$IMAGE_NAME:latest")
fi

# Build the -t arguments for docker build
DOCKER_TAGS=()
for tag in "${TAGS[@]}"; do
    DOCKER_TAGS+=(-t "$tag")
done

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  yooresh/bifrost Docker Image Builder                       ║"
echo "╠══════════════════════════════════════════════════════════════╣"
echo "║  Source:    $(cd "$PROJECT_ROOT" && git remote get-url origin 2>/dev/null || echo 'local')"
echo "║  Commit:    $GIT_SHA"
echo "║  Version:   $VERSION"
echo "║  Tags:      ${TAGS[*]}"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# ------------------------------------------------------------------
# Build the Docker image
# ------------------------------------------------------------------
BUILD_START=$(date +%s)
echo "🔨 Building Docker image..."
cd "$PROJECT_ROOT"

BUILD_ARGS=(
    --platform linux/amd64
    --progress=auto
    "${DOCKER_TAGS[@]}"
    --build-arg VERSION="$VERSION"
    # Map host.docker.internal to host gateway (Docker >= 20.10)
    --add-host host.docker.internal:host-gateway
)

# Pass GOPROXY build-arg if set (via env var or --goproxy flag)
if [[ -n "$GOPROXY" ]]; then
    echo "🔧 Using GOPROXY=$GOPROXY"
    # Check if the URL looks like an HTTP forward proxy (common forward-proxy ports)
    proxy_port=$(echo "$GOPROXY" | grep -oE ':[0-9]+' | head -1 | tr -d ':')
    if [[ -n "$proxy_port" ]] && [[ "$proxy_port" =~ ^(10808|8080|3128|8888|1080)$ ]]; then
        echo "   ⚠️  That looks like an HTTP forward proxy, not a Go module proxy."
        echo "   💡  Set HTTP_PROXY=http://host.docker.internal:$proxy_port instead and re-run without --goproxy"
    elif [[ "$GOPROXY" == *localhost* ]]; then
        echo "   ⚠️  localhost inside container won't reach the host. Use host.docker.internal:"
        if [[ -n "$proxy_port" ]]; then
            echo "   💡  --goproxy http://host.docker.internal:$proxy_port,direct"
        else
            echo "   💡  --goproxy http://host.docker.internal:PORT,direct (replace PORT with the actual port)"
        fi
    fi
    BUILD_ARGS+=(--build-arg "GOPROXY=$GOPROXY")
fi

# Pass HTTP_PROXY/HTTPS_PROXY/NO_PROXY build-args if set (from host environment)
# Auto-rewrite 127.0.0.1 and localhost to host.docker.internal so they reach
# the host's proxy services inside the build container.
for proxy_var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    if [[ -n "${!proxy_var:-}" ]]; then
        raw_value="${!proxy_var}"
        # Rewrite loopback addresses so they reach the host inside Docker
        if [[ "$raw_value" == *"127.0.0.1"* ]] || [[ "$raw_value" == *"localhost"* ]]; then
            cooked="${raw_value//127.0.0.1/host.docker.internal}"
            cooked="${cooked//localhost/host.docker.internal}"
            echo "🔗  Forwarding $proxy_var (rewritten: $cooked)"
            BUILD_ARGS+=(--build-arg "$proxy_var=$cooked")
        else
            echo "🔗  Forwarding $proxy_var=$raw_value"
            BUILD_ARGS+=(--build-arg "$proxy_var=$raw_value")
        fi
    fi
done
# NO_PROXY entries (localhost, loopback ranges, etc.) are safe as-is and
# don't need rewriting — they mean "don't proxy these destinations".
for proxy_var in NO_PROXY no_proxy; do
    if [[ -n "${!proxy_var:-}" ]]; then
        BUILD_ARGS+=(--build-arg "$proxy_var=${!proxy_var}")
        echo "🔗  Forwarding $proxy_var=${!proxy_var}"
    fi
done

docker buildx build     "${BUILD_ARGS[@]}"     -f Dockerfile     .

BUILD_END=$(date +%s)
BUILD_DURATION=$((BUILD_END - BUILD_START))
echo "✅ Build complete in ${BUILD_DURATION}s"
echo ""

# ------------------------------------------------------------------
# Push to Docker Hub
# ------------------------------------------------------------------
if [[ "$SKIP_PUSH" == "true" ]]; then
    echo "⏭️  Skipping push (--skip-push)"
    exit 0
fi

if [[ "$PUSH_IMAGE" == "false" ]]; then
    echo "----------------------------------------"
    read -r -p "🚀 Push these tags to Docker Hub? [y/N] " CONFIRM
    echo ""
    if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
        echo "⏭️  Push cancelled by user"
        exit 0
    fi
fi

echo "📤 Pushing to Docker Hub..."

# Pre-push DNS check: Docker daemon inherits /etc/resolv.conf from the host and
# often points at 127.0.0.53 (systemd-resolved), which may not reach upstream
# through a proxy tunnel. Verify before the push so the error message is helpful.
if ! getent hosts registry-1.docker.io >/dev/null 2>&1; then
    echo "⚠️  Cannot resolve registry-1.docker.io (DNS is broken inside Docker)."
    echo "   This usually means Docker daemon uses a local DNS stub resolver"
    echo "   that cannot reach the internet through your proxy/VPN setup."
    echo ""
    echo "   Fix: configure explicit upstream DNS for the Docker daemon:"
    echo '    sudo mkdir -p /etc/docker'
    echo "    echo '{\"dns\":[\"1.1.1.1\",\"8.8.8.8\"]}' | sudo tee /etc/docker/daemon.json"
    echo "    sudo systemctl restart docker"
    echo ""
    echo "   (The build still succeeded—use --skip-push next time to skip push.)"
    exit 1
fi

for tag in "${TAGS[@]}"; do
    echo "   Pushing $tag..."
    docker push "$tag"
done

echo ""
echo "✅ All tags pushed successfully!"
echo ""
echo "   Run the image:"
echo "   docker run -p 8080:8080 -v \$PWD/config.json:/app/data/config.json $IMAGE_NAME:$VERSION"