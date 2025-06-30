#!/usr/bin/env bash
set -euo pipefail

# Configuration
REPO_URL=https://gitlab.freedesktop.org/dbus/dbus.git
REPO_REF=main
IMAGE_NAME=dbus
BUILD_DIR=/tmp/dbuz/build

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
}

warn() {
    echo -e "${YELLOW}[WARN] $1${NC}"
}

cleanup() {
    log "Cleaning up temporary files..."
    rm -rf "${BUILD_DIR}"
}

trap cleanup EXIT

main() {
    log "Starting Docker build process..."

    if ! command -v docker &> /dev/null; then
        error "Docker is not installed or not in PATH"
        exit 1
    fi

    if ! command -v git &> /dev/null; then
        error "Git is not installed or not in PATH"
        exit 1
    fi

    log "Creating build directory: ${BUILD_DIR}"
    mkdir -p "${BUILD_DIR}"

    log "Cloning repository: ${REPO_URL}"
    git clone --depth 1 --branch "${REPO_REF}" "${REPO_URL}" "${BUILD_DIR}"

    cp ./tests/dbus/session.conf "${BUILD_DIR}"
    cp ./tests/dbus/entrypoint.sh "${BUILD_DIR}"

    log "Building Docker image: ${IMAGE_NAME}:${REPO_REF}"
    docker build -t "${IMAGE_NAME}:${REPO_REF}" "${BUILD_DIR}" -f ./tests/dbus/Dockerfile
}

main "$@"
