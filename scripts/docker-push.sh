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

# ------------------------------------------------------------------
# Docker registry DNS resolver
# Docker daemon on Linux uses Go's DNS resolver, which reads /etc/hosts
# before querying upstream servers. If your network blocks UDP:53 (common
# behind SOCKS5 proxies), we resolve registry-1.docker.io through a local
# SOCKS5-aware DNS proxy and pin the IP in /etc/hosts so docker push works.
# ------------------------------------------------------------------
resolve_docker_registry() {
    local registry="registry-1.docker.io"
    local dns_proxy="$SCRIPT_DIR/dns2socks5.py"

    # Already resolvable? Great, skip.
    if getent hosts "$registry" >/dev/null 2>&1; then
        return 0
    fi

    echo "⚠️  $registry does not resolve (UDP:53 is likely blocked)."

    # Start the SOCKS5-aware DNS proxy on an ephemeral port
    if [[ ! -f "$dns_proxy" ]]; then
        echo "   DNS proxy script not found at $dns_proxy"
        echo "   💡  Resolve the IP manually and add it to /etc/hosts:"
        echo "        echo '<IP> $registry' | sudo tee -a /etc/hosts"
        return 1
    fi

    local proxy_port=15353
    # Check if port is already taken
    if ss -tulpn 2>/dev/null | grep -q ":$proxy_port "; then
        echo "   Port $proxy_port in use, trying next..."
        proxy_port=15354
    fi

    echo "   Starting DNS proxy (SOCKS5 → upstream DNS) on port $proxy_port..."
    python3.12 "$dns_proxy" --port "$proxy_port" &
    local proxy_pid=$!
    # Give it time to start
    sleep 1

    # Resolve the registry IP
    local ip
    ip=$(dig @"127.0.0.1" -p "$proxy_port" "$registry" +short +timeout=5 2>/dev/null | head -1)

    kill "$proxy_pid" 2>/dev/null || true

    if [[ -z "$ip" ]]; then
        echo "   ❌ Could not resolve $registry even through the DNS proxy."
        echo "   Check that your SOCKS5 proxy is running on 127.0.0.1:10808."
        return 1
    fi

    # Add to /etc/hosts
    echo "   Resolved $registry → $ip"
    if grep -q "$registry" /etc/hosts 2>/dev/null; then
        # Update existing entry
        if echo "$ip $registry" | sudo tee /etc/hosts.tmp >/dev/null 2>&1; then
            sudo mv /etc/hosts.tmp /etc/hosts
            echo "   ✅ Updated /etc/hosts entry for $registry"
        else
            echo "   ⚠️  Could not update /etc/hosts (sudo required)."
            echo "   💡  Run this manually:"
            echo "        echo '$ip $registry' | sudo tee -a /etc/hosts"
            return 1
        fi
    else
        if echo "$ip $registry" | sudo tee -a /etc/hosts >/dev/null 2>&1; then
            echo "   ✅ Added $registry → $ip to /etc/hosts"
        else
            echo "   ⚠️  Could not add to /etc/hosts (sudo required)."
            echo "   💡  Run this manually:"
            echo "        echo '$ip $registry' | sudo tee -a /etc/hosts"
            return 1
        fi
    fi

    # Verify
    if getent hosts "$registry" >/dev/null 2>&1; then
        echo "   ✅ Docker daemon can now resolve $registry"
        return 0
    else
        echo "   ⚠️  /etc/hosts updated but Docker daemon still can't resolve."
        echo "   The daemon may cache DNS — try restarting Docker:"
        echo "        sudo systemctl restart docker"
        return 1
    fi
}

resolve_docker_registry || exit 1

for tag in "${TAGS[@]}"; do
    echo "   Pushing $tag..."
    docker push "$tag"
done

echo ""
echo "✅ All tags pushed successfully!"
echo ""
echo "   Run the image:"
echo "   docker run -p 8080:8080 -v \$PWD/config.json:/app/data/config.json $IMAGE_NAME:$VERSION"