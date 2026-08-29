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
#   GOPROXY  If set, used as the Go module proxy (overridden by --goproxy)
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
    sed -n 's/^#\s\?//p' "${BASH_SOURCE[0]}" | head -n -1
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
    if [[ "$GOPROXY" == *localhost* ]]; then
        echo "   ⚠️  localhost inside container won't reach the host. Use host.docker.internal instead:"
        echo "   💡  --goproxy http://host.docker.internal:10808,direct"
    fi
    BUILD_ARGS+=(--build-arg "GOPROXY=$GOPROXY")
fi

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
for tag in "${TAGS[@]}"; do
    echo "   Pushing $tag..."
    docker push "$tag"
done

echo ""
echo "✅ All tags pushed successfully!"
echo ""
echo "   Run the image:"
echo "   docker run -p 8080:8080 -v \$PWD/config.json:/app/data/config.json $IMAGE_NAME:$VERSION"
