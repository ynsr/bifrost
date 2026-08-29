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
#
# If HTTP_PROXY is not set in the environment but xray SOCKS5 proxy is
# detected on the default port, auto-set it (xray also speaks HTTP CONNECT
# on the same port, so it works as an HTTPS proxy for Go module downloads).
auto_proxy=""
if [[ -z "${HTTP_PROXY:-}" && -z "${HTTPS_PROXY:-}" ]]; then
    if timeout 1 bash -c '</dev/tcp/127.0.0.1/10808' 2>/dev/null; then
        auto_proxy="http://host.docker.internal:10808"
        echo "🔗  Auto-set HTTP_PROXY/HTTPS_PROXY=$auto_proxy (detected xray proxy)"
    fi
fi

for proxy_var in HTTP_PROXY HTTPS_PROXY http_proxy https_proxy; do
    if [[ -n "${!proxy_var:-}" ]]; then
        raw_value="${!proxy_var}"
    elif [[ -n "$auto_proxy" ]]; then
        raw_value="$auto_proxy"
    else
        continue
    fi
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
done

# When using auto-detected proxy, let Go use the default module proxy
# (https://proxy.golang.org,direct) through the HTTP proxy tunnel.
# The HTTP CONNECT proxy handles DNS resolution for proxy.golang.org,
# so we don't need to set GOPROXY=direct (and alpine has no git binary).
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
# behind SOCKS5 proxies), we resolve all Docker Hub domains through a
# local SOCKS5-aware DNS proxy and pin the IPs in /etc/hosts so docker
# push works end-to-end.
# ------------------------------------------------------------------
resolve_docker_registry() {
    local dns_proxy="$SCRIPT_DIR/dns2socks5.py"
    # All domains a docker push may need — includes the registry, OAuth
    # token endpoint, and the CDN blob-storage host.
    local domains=(registry-1.docker.io auth.docker.io production.cloudflare.docker.com)
    local need_resolve=()

    for domain in "${domains[@]}"; do
        if ! getent hosts "$domain" >/dev/null 2>&1; then
            need_resolve+=("$domain")
        fi
    done

    if [[ ${#need_resolve[@]} -eq 0 ]]; then
        return 0
    fi

    echo "⚠️  ${need_resolve[*]} do not resolve (UDP:53 is likely blocked)."

    if [[ ! -f "$dns_proxy" ]]; then
        echo "   DNS proxy script not found at $dns_proxy"
        echo "   💡  Add IPs to /etc/hosts manually"
        return 1
    fi

    # Find a free port
    local proxy_port=15353
    while ss -tulpn 2>/dev/null | grep -q ":$proxy_port "; do
        ((proxy_port++))
        if [[ "$proxy_port" -gt 15500 ]]; then
            echo "   ❌ No free port available."
            return 1
        fi
    done

    echo "   Starting DNS proxy (SOCKS5 → upstream DNS) on port $proxy_port..."
    python3.12 "$dns_proxy" --port "$proxy_port" &
    local proxy_pid=$!
    sleep 1

    if ! kill -0 "$proxy_pid" 2>/dev/null; then
        echo "   ❌ DNS proxy failed to start. pip3 install pysocks"
        return 1
    fi

    local resolved=0
    local pending_update=""

    for domain in "${need_resolve[@]}"; do
        # Use +noall +answer and grep for A records only — +short can return
        # a CNAME on line 1 (e.g. auth.docker.io → auth.docker.io.cdn.cloudflare.net)
        # which is useless in /etc/hosts. We need a raw IPv4.
        local ip
        ip=$(dig @"127.0.0.1" -p "$proxy_port" "$domain" +noall +answer +timeout=5 2>/dev/null \
            | awk '$4 == "A" {print $5; exit}')
        if [[ -n "$ip" ]]; then
            echo "   Resolved $domain → $ip"
            pending_update+="$ip $domain # docker-push.sh auto-entry"$'\n'
            ((resolved++))
        else
            echo "   ❌ Could not resolve $domain (no A record)"
        fi
    done

    kill "$proxy_pid" 2>/dev/null || true

    if [[ "$resolved" -eq 0 ]]; then
        echo "   ❌ Could not resolve any Docker Hub domains."
        echo "   Check your SOCKS5 proxy on 127.0.0.1:10808."
        return 1
    fi

    # Atomically update marker-commented lines in /etc/hosts.
    # For each domain we just resolved, remove its old marker line(s),
    # then append the fresh entry. Other marker lines (from previous
    # runs where the IP is still valid) are preserved.
    local new_hosts
    new_hosts=$(mktemp)
    cp /etc/hosts "$new_hosts" 2>/dev/null || : > "$new_hosts"
    for domain in "${need_resolve[@]}"; do
        sed -i "/^.* $domain # docker-push.sh auto-entry$/d" "$new_hosts"
    done
    printf '%s' "$pending_update" >> "$new_hosts"

    if sudo tee /etc/hosts < "$new_hosts" >/dev/null 2>&1; then
        echo "   ✅ Added/resolved $resolved domain(s) in /etc/hosts"
        # Docker daemon caches /etc/hosts at startup and does not re-read
        # it on changes. Restart Docker so the Go resolver picks up the
        # new entries before we push.
        echo "   🔄 Restarting Docker daemon to pick up /etc/hosts changes..."
        if sudo systemctl restart docker >/dev/null 2>&1; then
            echo "   ✅ Docker restart complete"
        else
            echo "   ⚠️  Could not restart Docker automatically."
            echo "   💡  Run: sudo systemctl restart docker"
            echo "   Then re-run ./scripts/docker-push.sh to push."
            rm -f "$new_hosts"
            return 1
        fi
    else
        echo "   ⚠️  Could not update /etc/hosts (sudo required)."
        echo "   Run this manually, then re-run:"
        echo "$pending_update" | sed 's/^/        /'
        rm -f "$new_hosts"
        return 1
    fi
    rm -f "$new_hosts"

    # Final verification
    local all_ok=0
    for domain in "${domains[@]}"; do
        if getent hosts "$domain" >/dev/null 2>&1; then
            ((all_ok++))
        fi
    done

    if [[ "$all_ok" -eq "${#domains[@]}" ]]; then
        echo "   ✅ All Docker Hub domains resolvable. Ready to push."
        return 0
    else
        echo "   ⚠️  ${all_ok}/${#domains[@]} domains resolved (push may still need more)."
        return 0
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