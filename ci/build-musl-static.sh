#!/bin/sh
# ci/build-musl-static.sh
#
# Build fully-static (musl libc) binaries of zmap inside an Alpine Linux
# container. Works on any architecture Alpine supports; for architectures
# different from the runner CPU it relies on QEMU user-mode emulation
# (docker/setup-qemu-action).
#
# Usage (inside the container):
#   TARGET_ARCH=x86_64 sh ci/build-musl-static.sh
#
# Environment:
#   TARGET_ARCH          target arch label used for output dir (e.g. x86_64)
#   HOST_UID / HOST_GID  uid:gid outputs are chown'd back to (optional)
#
# Produced artifacts:
#   dist/linux-${TARGET_ARCH}/{zmap,zblocklist,ziterate,ztee}
#   dist/.version   (version string used by ci/package-musl.sh)
set -eux

: "${TARGET_ARCH:?TARGET_ARCH must be set (e.g. x86_64)}"

echo "==> container uname -m: $(uname -m) | target arch: ${TARGET_ARCH}"

# ---------------------------------------------------------------------------
# Dependencies. Alpine -dev packages ship static archives (.a); for gmp and
# libunistring the static archives live in the dedicated -static subpackages.
# ---------------------------------------------------------------------------
apk update
apk add --no-cache \
    build-base cmake pkgconf git file \
    linux-headers \
    flex byacc gengetopt \
    libpcap-dev \
    json-c-dev \
    judy-dev \
    gmp-dev gmp-static \
    libunistring-dev libunistring-static \
    zlib-static

# The workspace is bind-mounted and owned by the CI user, not by root.
# zmap embeds `git log` output (build commit) via CMakeVersion.txt at build
# time, so git must be allowed to operate on the repository first.
git config --global --add safe.directory '*'
git log -n 1 --pretty=format:"build commit: %h - %ad" || true

# ---------------------------------------------------------------------------
# Configure: force CMake to look for static archives and link statically.
# Alpine gcc defaults to PIE; -fno-pie/-no-pie keeps the result a plain
# statically-linked executable. -s strips symbols to reduce binary size.
# ---------------------------------------------------------------------------
cmake -S . -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_FIND_LIBRARY_SUFFIXES='.a' \
    -DCMAKE_C_FLAGS='-static -fno-pie' \
    -DCMAKE_EXE_LINKER_FLAGS='-static -no-pie -s'

# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------
cmake --build build --parallel "$(nproc)"

# ---------------------------------------------------------------------------
# Smoke test: actually execute zmap inside this (possibly emulated) machine
# ---------------------------------------------------------------------------
ZMAP_BIN="$(find build -type f -name zmap | head -n1)"
if [ -z "${ZMAP_BIN}" ]; then
    echo "ERROR: zmap binary not found in build tree" >&2
    exit 1
fi
echo "==> smoke test: ${ZMAP_BIN} --version"
"${ZMAP_BIN}" --version

# ---------------------------------------------------------------------------
# Stage the four tools
# ---------------------------------------------------------------------------
OUTDIR="dist/linux-${TARGET_ARCH}"
mkdir -p "${OUTDIR}"
for tool in zmap zblocklist ziterate ztee; do
    BIN="$(find build -type f -name "${tool}" | head -n1)"
    if [ -z "${BIN}" ]; then
        echo "ERROR: ${tool} was not built" >&2
        exit 1
    fi
    cp "${BIN}" "${OUTDIR}/${tool}"
done

# ---------------------------------------------------------------------------
# Sanity check: every binary must be truly static
# ---------------------------------------------------------------------------
for BIN in "${OUTDIR}"/*; do
    if file "${BIN}" | grep -q 'dynamically linked'; then
        echo "ERROR: ${BIN} is dynamically linked, refusing to publish" >&2
        exit 1
    fi
    echo "static OK: ${BIN}"
done
ls -la "${OUTDIR}"

git describe --tags --always --dirty > dist/.version 2>/dev/null \
    || echo "dev" > dist/.version

# ---------------------------------------------------------------------------
# Hand outputs back to the CI user (the container runs as root)
# ---------------------------------------------------------------------------
if [ "$(id -u)" = "0" ] && [ -n "${HOST_UID:-}" ]; then
    chown -R "${HOST_UID}:${HOST_GID:-${HOST_UID}}" build dist || true
fi

echo "==> static musl build for ${TARGET_ARCH} finished"
