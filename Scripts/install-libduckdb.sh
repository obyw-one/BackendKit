#!/bin/sh
# Install the official libduckdb pinned in Scripts/libduckdb.lock, for building and running BackendKitDuckDB on Linux.
#
#   Scripts/install-libduckdb.sh [PREFIX]          PREFIX defaults to $LIBDUCKDB_PREFIX, then /usr/local
#
# Installs   PREFIX/lib/libduckdb.so   PREFIX/include/duckdb.h   PREFIX/lib/pkgconfig/duckdb.pc
#
# The release archive is downloaded from DuckDB's GitHub release (amd64 and arm64 are picked from `uname -m`) and its
# sha256 is compared with the digest in the lock file BEFORE anything is extracted or installed. Any failure (no
# download tool, a failed download, a digest mismatch, a missing file in the archive, an unknown architecture) stops
# the script with a non-zero exit and an explanation on stderr. It never falls back to an unverified file.
#
# LIBDUCKDB_ARCHIVE=/path/to/duckdb-shared-libs-linux-<arch>.tar.gz   use an archive you already have (offline builds);
#                                                                      it is verified against the same digest.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
lock="$here/libduckdb.lock"

fail() {
    echo "install-libduckdb: $*" >&2
    exit 1
}

[ "$(uname -s)" = "Linux" ] || fail "this installs the Linux library; on Apple platforms BackendKitDuckDB uses duckdb-swift and needs nothing installed"

lock_value() {
    value=$(sed -n "s/^$1=//p" "$lock")
    [ -n "$value" ] || fail "$1 is missing from $lock"
    printf '%s' "$value"
}

version=$(lock_value LIBDUCKDB_VERSION)
case "$(uname -m)" in
    x86_64 | amd64) arch=amd64; expected=$(lock_value LIBDUCKDB_SHA256_AMD64) ;;
    aarch64 | arm64) arch=arm64; expected=$(lock_value LIBDUCKDB_SHA256_ARM64) ;;
    *) fail "unsupported architecture $(uname -m): the official DuckDB Linux libraries are amd64 and arm64" ;;
esac

prefix=${1:-${LIBDUCKDB_PREFIX:-/usr/local}}
asset="duckdb-shared-libs-linux-$arch.tar.gz"
url="https://github.com/duckdb/duckdb/releases/download/$version/$asset"

if command -v sha256sum >/dev/null 2>&1; then
    digest_of() { sha256sum "$1" | cut -d ' ' -f 1; }
elif command -v shasum >/dev/null 2>&1; then
    digest_of() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
else
    fail "neither sha256sum nor shasum is installed, so the download cannot be verified"
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM

if [ -n "${LIBDUCKDB_ARCHIVE:-}" ]; then
    [ -f "$LIBDUCKDB_ARCHIVE" ] || fail "LIBDUCKDB_ARCHIVE=$LIBDUCKDB_ARCHIVE is not a file"
    archive=$LIBDUCKDB_ARCHIVE
else
    archive="$work/$asset"
    echo "install-libduckdb: downloading $url"
    # curl, else wget, else python3: the official swift Linux images ship python3 but neither curl nor wget.
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location --retry 3 --output "$archive" "$url" || fail "download of $url failed"
    elif command -v wget >/dev/null 2>&1; then
        wget --quiet --tries=3 --output-document="$archive" "$url" || fail "download of $url failed"
    elif command -v python3 >/dev/null 2>&1; then
        python3 -I -c 'import sys, urllib.request; urllib.request.urlretrieve(sys.argv[1], sys.argv[2])' "$url" "$archive" || fail "download of $url failed"
    else
        fail "none of curl, wget or python3 is installed (or set LIBDUCKDB_ARCHIVE to an archive you downloaded from $url)"
    fi
fi

actual=$(digest_of "$archive")
if [ "$actual" != "$expected" ]; then
    fail "sha256 mismatch for $asset ($version): expected $expected, got $actual. Nothing was installed."
fi
echo "install-libduckdb: sha256 verified ($asset, $version)"

mkdir "$work/extract"
tar -xzf "$archive" -C "$work/extract" libduckdb.so duckdb.h || fail "$asset does not contain libduckdb.so and duckdb.h"
[ -s "$work/extract/libduckdb.so" ] && [ -s "$work/extract/duckdb.h" ] || fail "$asset has an empty libduckdb.so or duckdb.h"

mkdir -p "$prefix/lib/pkgconfig" "$prefix/include" || fail "cannot create $prefix (run with a writable PREFIX, or as root)"
cp "$work/extract/libduckdb.so" "$prefix/lib/libduckdb.so"
cp "$work/extract/duckdb.h" "$prefix/include/duckdb.h"
cat > "$prefix/lib/pkgconfig/duckdb.pc" <<PC
prefix=$prefix
libdir=\${prefix}/lib
includedir=\${prefix}/include

Name: duckdb
Description: DuckDB embedded database, official release $version (installed by BackendKit's Scripts/install-libduckdb.sh)
Version: ${version#v}
Libs: -L\${libdir} -lduckdb
Cflags: -I\${includedir}
PC

# A system prefix is made known to the dynamic loader. Any other prefix needs LD_LIBRARY_PATH at run time: SwiftPM
# refuses an rpath flag coming from pkg-config.
case "$prefix" in
    /usr | /usr/local)
        if [ "$(id -u)" = "0" ] && command -v ldconfig >/dev/null 2>&1; then ldconfig; fi
        ;;
esac

echo "install-libduckdb: installed DuckDB $version ($arch) under $prefix"
echo "  build:   PKG_CONFIG_PATH=$prefix/lib/pkgconfig swift build"
echo "  run:     libduckdb.so must be found by the loader: it is under a system prefix, or set LD_LIBRARY_PATH=$prefix/lib"
