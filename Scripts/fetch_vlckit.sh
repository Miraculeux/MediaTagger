#!/usr/bin/env bash
# Download and unpack VLCKit (macOS xcframework) into Frameworks/.
# The framework is NOT committed to the repo; run this once after cloning.
# Optional: set VLCKIT_TARBALL=/path/to/VLCKit-*.tar.xz to install from a
# local download instead of fetching over the network.
#
# Usage: bash Scripts/fetch_vlckit.sh
set -euo pipefail

VERSION="3.7.3-319ed2c0-79128878"
URL="https://download.videolan.org/cocoapods/prod/VLCKit-${VERSION}.tar.xz"

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${REPO_ROOT}/Frameworks"
STAMP="${DEST}/.vlckit-version"

if [[ -d "${DEST}/VLCKit.xcframework" && -f "${STAMP}" && "$(cat "${STAMP}")" == "${VERSION}" ]]; then
    echo "VLCKit ${VERSION} already present in Frameworks/."
    exit 0
fi

mkdir -p "${DEST}"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

if [[ -n "${VLCKIT_TARBALL:-}" && -f "${VLCKIT_TARBALL}" ]]; then
    echo "Using local archive: ${VLCKIT_TARBALL}"
    cp "${VLCKIT_TARBALL}" "${TMP}/VLCKit.tar.xz"
else
    echo "Downloading VLCKit ${VERSION} (~84 MB)…"
    curl -L --progress-bar -C - --retry 5 --retry-delay 2 \
        -o "${TMP}/VLCKit.tar.xz" "${URL}"
fi

echo "Unpacking…"
tar -xJf "${TMP}/VLCKit.tar.xz" -C "${TMP}"

XCFW="$(find "${TMP}" -name VLCKit.xcframework -maxdepth 6 -type d | head -1)"
if [[ -z "${XCFW}" ]]; then
    echo "ERROR: VLCKit.xcframework not found in archive." >&2
    exit 1
fi

rm -rf "${DEST}/VLCKit.xcframework"
cp -R "${XCFW}" "${DEST}/VLCKit.xcframework"
echo "${VERSION}" > "${STAMP}"

echo "Installed VLCKit.xcframework -> ${DEST}/VLCKit.xcframework"
