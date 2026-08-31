#!/bin/bash
# Refactored Droidspaces RootFS Build Engine (Single Template Mode)
# This script is designed to be called by a parent loop or CI matrix.

# Configuration
: "${VERSION:=dev}"
DATE=$(date +%Y%m%d)
ARCH=$(uname -m)
: "${ENABLE_systemd257:=false}"

# Parse arguments
while getopts "i:v:S:" opt; do
  case $opt in
    i) DOCKERFILE="$OPTARG" ;;
    v) VERSION="$OPTARG" ;;
    S) ENABLE_systemd257="$OPTARG" ;; # systemd 257 旧内核兼容 (Kali Linux)
    *) echo "Usage: $0 -i <template.Dockerfile> [-v <version>] [-S <true|false>]" ; exit 1 ;;
  esac
done

case "$ENABLE_systemd257" in
  true|false) ;;
  *) echo "Error: -S only supports true or false." >&2; exit 1 ;;
esac

if [ -z "$DOCKERFILE" ]; then
    echo "Error: Template file (-i) is required."
    exit 1
fi

if [ ! -f "$DOCKERFILE" ]; then
    echo "Error: Template file '$DOCKERFILE' not found."
    exit 1
fi

# Extract prefix (e.g., Ubuntu-24.04 from Ubuntu-24.04.Dockerfile)
PREFIX=$(echo "$DOCKERFILE" | sed 's/\.Dockerfile//')

echo "========================================================="
echo " Starting Build: $PREFIX"
echo " Using Template: $DOCKERFILE"
echo " Build Version : $VERSION"
echo " systemd 257 Old-Kernel Compat (Kali): $ENABLE_systemd257"
echo "========================================================="

# 1. Environment Initialization (Native)
echo "Ensuring native build environment..."
# In native mode, no QEMU or binfmt initialization is required.

# 2. Builder Setup
if ! docker buildx inspect droidspaces-builder >/dev/null 2>&1; then
    echo "Creating new buildx builder: droidspaces-builder"
    docker buildx create --name droidspaces-builder --driver docker-container --use
else
    echo "Using existing buildx builder: droidspaces-builder"
    docker buildx use droidspaces-builder
fi

# Bootstrap to ensure it's ready
docker buildx inspect --bootstrap || echo "Warning: Bootstrap failed, attempting to continue..."

set -e

# 3. Core Build Process
TEMP_TAR="custom-${PREFIX}-rootfs.tar"
FINAL_NAME="${PREFIX}-Droidspaces-rootfs-${ARCH}-${DATE}-${VERSION}.tar.xz"

echo "Running Docker Build (Native)..."
docker buildx build \
  --target export \
  --output type=tar,dest="$TEMP_TAR" \
  --build-arg ENABLE_systemd257_ARG="$ENABLE_systemd257" \
  -f "$DOCKERFILE" \
  .

# 4. Packaging
echo "Compressing build output (xz ultra - Multi-threaded)..."
xz -T0 -9 -f "$TEMP_TAR"

echo "Finalizing: $FINAL_NAME"
mv "${TEMP_TAR}.xz" "$FINAL_NAME"

echo "========================================================="
echo " Successfully completed: $FINAL_NAME"
echo "========================================================="
