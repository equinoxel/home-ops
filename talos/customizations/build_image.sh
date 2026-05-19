#!/usr/bin/env bash
#
# Build a custom Talos Linux image for Raspberry Pi CM5 nodes.
#
# This script uses the Talos imager to produce a raw disk image and an
# installer image with the SBC overlay and system extensions baked in.
# The overlay's config.txt is sourced from rpi_generic_cm5.yaml.
#
# Usage:
#   ./build_image.sh                  # build both disk image and installer
#   ./build_image.sh --disk-only      # build only the raw disk image (for initial flash)
#   ./build_image.sh --installer-only # build only the installer image (for upgrades)
#
# Prerequisites:
#   - Docker (with buildx / multi-platform support for arm64)
#   - yq (for reading talenv.yaml)
#
# Outputs (in ./_out/):
#   metal-arm64.raw.xz   — Raw disk image for initial NVMe flash
#   installer-arm64.tar   — OCI installer image for talosctl upgrade
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
OUT_DIR="${SCRIPT_DIR}/_out"

# ---------------------------------------------------------------------------
# Configuration — pulled from talenv.yaml and rpi_generic_cm5.yaml
# ---------------------------------------------------------------------------
TALENV="${SCRIPT_DIR}/../talenv.yaml"
OVERLAY_CONFIG="${SCRIPT_DIR}/rpi_generic_cm5.yaml"

if [[ ! -f "${TALENV}" ]]; then
    echo "ERROR: talenv.yaml not found at ${TALENV}" >&2
    exit 1
fi

if [[ ! -f "${OVERLAY_CONFIG}" ]]; then
    echo "ERROR: rpi_generic_cm5.yaml not found at ${OVERLAY_CONFIG}" >&2
    exit 1
fi

TALOS_VERSION="$(yq '.talosVersion' "${TALENV}")"
OVERLAY_IMAGE="$(yq '.overlay.image' "${OVERLAY_CONFIG}")"
OVERLAY_NAME="$(yq '.overlay.name' "${OVERLAY_CONFIG}")"

# Imager and overlay image references
IMAGER_IMAGE="ghcr.io/siderolabs/imager:${TALOS_VERSION}"
# The overlay tag should match the Talos minor version series.
# Check https://github.com/siderolabs/sbc-raspberrypi/releases for the
# correct tag. Update this if the overlay version diverges from Talos.
OVERLAY_TAG="${OVERLAY_TAG:-v0.2.0}"
OVERLAY_REF="ghcr.io/${OVERLAY_IMAGE}:${OVERLAY_TAG}"

# System extensions to include in the image.
# These must match the schematic used in talconfig.yaml talosImageURL.
# To find what extensions are in your current schematic, query:
#   curl -s https://factory.talos.dev/schematics/<schematic-id>.yaml
#
# Add or remove extensions as needed. Each entry is a full OCI reference.
EXTENSIONS=(
    "ghcr.io/siderolabs/iscsi-tools:v0.2.0"
    "ghcr.io/siderolabs/util-linux-tools:2.41.2"
)

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
BUILD_DISK=true
BUILD_INSTALLER=true

for arg in "$@"; do
    case "${arg}" in
        --disk-only)
            BUILD_INSTALLER=false
            ;;
        --installer-only)
            BUILD_DISK=false
            ;;
        --help|-h)
            head -25 "$0" | grep '^#' | sed 's/^# \?//'
            exit 0
            ;;
        *)
            echo "Unknown argument: ${arg}" >&2
            exit 1
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
build_extension_args() {
    local args=""
    for ext in "${EXTENSIONS[@]}"; do
        args+=" --system-extension-image=${ext}"
    done
    echo "${args}"
}

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
mkdir -p "${OUT_DIR}"

echo "============================================"
echo "Talos CM5 Image Builder"
echo "============================================"
echo "Talos version : ${TALOS_VERSION}"
echo "Imager        : ${IMAGER_IMAGE}"
echo "Overlay       : ${OVERLAY_REF} (${OVERLAY_NAME})"
echo "Extensions    : ${EXTENSIONS[*]}"
echo "Output dir    : ${OUT_DIR}"
echo "============================================"
echo ""

EXTENSION_ARGS="$(build_extension_args)"

if [[ "${BUILD_DISK}" == true ]]; then
    echo ">>> Building raw disk image (metal-arm64.raw.xz) ..."
    echo "    This produces a flashable image for initial NVMe installation."
    echo ""

    docker run --rm -t \
        -v "${OUT_DIR}:/out" \
        -v /dev:/dev \
        --privileged \
        "${IMAGER_IMAGE}" metal \
        --arch arm64 \
        --overlay-image="${OVERLAY_REF}" \
        --overlay-name="${OVERLAY_NAME}" \
        --overlay-option="configTxtAppend=$(yq '.overlay.options.configTxtAppend' "${OVERLAY_CONFIG}")" \
        ${EXTENSION_ARGS}

    echo ""
    echo ">>> Disk image built: ${OUT_DIR}/metal-arm64.raw.xz"
    echo "    Flash with: xz -d metal-arm64.raw.xz && dd if=metal-arm64.raw of=/dev/<nvme> bs=4M status=progress"
    echo ""
fi

if [[ "${BUILD_INSTALLER}" == true ]]; then
    echo ">>> Building installer image (installer-arm64.tar) ..."
    echo "    This produces an OCI image for talosctl upgrade."
    echo ""

    docker run --rm -t \
        -v "${OUT_DIR}:/out" \
        -v /dev:/dev \
        --privileged \
        "${IMAGER_IMAGE}" installer \
        --arch arm64 \
        --overlay-image="${OVERLAY_REF}" \
        --overlay-name="${OVERLAY_NAME}" \
        --overlay-option="configTxtAppend=$(yq '.overlay.options.configTxtAppend' "${OVERLAY_CONFIG}")" \
        ${EXTENSION_ARGS}

    echo ""
    echo ">>> Installer image built: ${OUT_DIR}/installer-arm64.tar"
    echo ""
    echo "    To use for upgrades:"
    echo "    1. Load into a registry:"
    echo "       crane push ${OUT_DIR}/installer-arm64.tar <registry>/talos-installer:${TALOS_VERSION}-cm5"
    echo "    2. Update talconfig.yaml talosImageURL for blade nodes to point to your registry"
    echo "    3. Run: task talos:upgrade-node IP=<blade-ip>"
    echo ""
    echo "    Or load locally and upgrade directly:"
    echo "       talosctl -n <blade-ip> upgrade --image=<registry>/talos-installer:${TALOS_VERSION}-cm5"
    echo ""
fi

echo "============================================"
echo "Build complete."
echo "============================================"
