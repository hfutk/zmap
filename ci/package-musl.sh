#!/usr/bin/env bash
# ci/package-musl.sh <arch>
#
# Runs on the CI runner (outside the container). Bundles the binaries built
# by ci/build-musl-static.sh into a named release tarball and computes its
# sha256 checksum.
#
# Inputs:
#   $1                      target arch label (e.g. x86_64)
#   dist/linux-<arch>/      binaries produced by the build script
#   dist/.version           version string (git describe fallback)
#
# Outputs (in out/):
#   zmap-<version>-linux-<arch>-musl-static.tar.gz
#   zmap-<version>-linux-<arch>-musl-static.tar.gz.sha256
set -euo pipefail

ARCH="${1:?usage: package-musl.sh <arch>}"
SRC="dist/linux-${ARCH}"
OUT="out"

if [ ! -d "${SRC}" ]; then
    echo "ERROR: ${SRC} does not exist (run ci/build-musl-static.sh first)" >&2
    exit 1
fi

VERSION="$(git describe --tags --always --dirty 2>/dev/null \
    || cat dist/.version 2>/dev/null \
    || echo dev)"

NAME="zmap-${VERSION}-linux-${ARCH}-musl-static"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT

cp "${SRC}"/* "${STAGE}/"

{
    echo "zmap - statically linked musl build (Alpine Linux ${ALPINE_VERSION:-3.22})"
    echo "================================================================="
    echo "version : ${VERSION}"
    echo "commit  : ${GITHUB_SHA:-unknown}"
    echo "arch    : ${ARCH}"
    echo "built   : $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo
    echo "Included tools:"
    for f in zmap zblocklist ziterate ztee; do
        if [ -f "${STAGE}/${f}" ]; then
            echo "  - ${f}"
        fi
    done
    echo
    echo "All binaries are fully static (musl libc): no runtime dependencies,"
    echo "they run on any Linux distribution of matching architecture."
    echo
    echo "Usage notes:"
    echo "  * zmap requires root (or CAP_NET_RAW) to send packets."
    echo "  * Configuration files are expected in /etc/zmap; copy them from"
    echo "    the conf/ directory of the source tree if needed."
    echo "  * Example: sudo ./zmap --version"
} > "${STAGE}/README.txt"

mkdir -p "${OUT}"
tar -czf "${OUT}/${NAME}.tar.gz" -C "${STAGE}" .
(cd "${OUT}" && sha256sum "${NAME}.tar.gz" > "${NAME}.tar.gz.sha256")

echo "packaged: ${OUT}/${NAME}.tar.gz"
cat "${OUT}/${NAME}.tar.gz.sha256"
