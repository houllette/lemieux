#!/usr/bin/env bash
# Build the Erlang/OTP runtime the Linux lmx archive ships, so the archive runs
# on any x86-64 glibc distribution with glibc 2.34 or newer, not only on the
# Ubuntu and Debian releases whose libraries match the build host.
#
#     scripts/build-static-otp.sh PREFIX            build (or reuse) and verify
#     scripts/build-static-otp.sh --verify PREFIX   verify an existing build
#     scripts/build-static-otp.sh --check-pins      every download has a checksum
#
# The OTP that setup-beam installs links the build host's libcrypto.so.3 and
# libtinfo.so.6, and an archive built with it broke on most of the Linux
# world: Fedora, RHEL 9 and its rebuilds, and Amazon Linux 2023 ship a
# libcrypto without the SM4 ciphers OTP's crypto expects (`EVP_sm4_cbc`), so
# crypto fails to load; openSUSE's libtinfo lacks a symbol beam.smp uses
# (`strfnames`), so the VM does not start; Debian 12 slim images have no
# libcrypto.so.3 at all. So:
#
#   * OpenSSL (the LTS release pinned below) is linked into crypto.so
#     (--disable-dynamic-ssl-lib); nothing loads a libcrypto at run time;
#   * OTP is built --without-termcap, so beam.smp needs no libtinfo. lmx draws
#     its terminal UI through ex_ratatui, not the Erlang shell's line editor;
#   * libstdc++ and libgcc are linked statically, so no GLIBCXX floor either.
#
# What remains is glibc (libc, libm, the dynamic loader), and building in
# ubuntu:22.04 keeps that floor at the GLIBC_2.34 symbols the result needs.
# The launch audit ran this configuration's archive on Fedora 44, Rocky 9,
# Amazon Linux 2023, openSUSE Leap 15.6 and Tumbleweed, Debian 12 slim, and
# Ubuntu 22.04 and 24.04. --verify fails if any OTP binary needs a library
# outside glibc, so a configure change cannot quietly undo this.
#
# OTP and Elixir are the versions .tool-versions pins: the release must run
# what CI tests, and extensions built for the binary record both. OpenSSL is
# pinned here; it is compiled into the binary, so an OpenSSL security release
# needs a new lmx release with OPENSSL_VERSION and its checksum bumped. Every
# download is checked against a SHA-256 in pinned_sha256 below. Bumping a
# version means adding its checksum there, and --check-pins, which CI runs,
# fails as soon as .tool-versions names a version that table lacks rather
# than when a release is tagged.
#
# PREFIX receives openssl/ (the static library OTP linked), otp/, elixir/ and
# BUILD-INFO, which records the inputs, compiler and C library included; a
# PREFIX whose BUILD-INFO matches is reused, so a restored cache skips the
# build. Put PREFIX/otp/bin and PREFIX/elixir/bin on PATH to use it.
#
# Rebuilds aim to be reproducible. A hot upgrade requires the release's
# identity (Lmx.Release.identity/2) to be unchanged, and that identity covers
# the modules and native libraries of every OTP application the release ships
# (crypto.so among them), which this script compiles anew for every tag. So
# the sources are built under PREFIX/src, a fixed path; OTP is configured
# with --enable-deterministic-build, which keeps absolute paths out of its
# modules; and OpenSSL's build date comes from its release, not the clock.
# That is unverified until two builds are compared: verification ends by
# printing an "OTP application digest" over every OTP application's ebin/
# and priv/, and two builds agree when their digests do. Before an upgrade
# plan declares a hot Linux upgrade, compare the digest of the previous
# release's build with a fresh one. If they differ, the release build stops
# with "runtime, dependencies or native assets changed; review a restart
# decision", and Linux takes a restart.
#
# Needs Linux, a C and C++ toolchain, make, perl, curl, tar, unzip, sha256sum
# and binutils (readelf, objdump). On Ubuntu 22.04, as root:
#
#     apt-get install build-essential perl autoconf m4 curl ca-certificates unzip binutils
#
# Release CI runs it in an ubuntu:22.04 container. The same build locally,
# from the repository root (emulated, and slow, on a non-x86-64 machine):
#
#     docker run --rm --platform linux/amd64 -e ERL_FLAGS='+JMsingle true' -v "$PWD:/src" -w /src ubuntu:22.04 sh -c \
#       'apt-get update && apt-get install -y build-essential perl autoconf m4 curl ca-certificates unzip binutils && scripts/build-static-otp.sh /opt/lmx-static-otp'
#
# ERL_FLAGS='+JMsingle true' is for Apple Silicon, where the container runs
# under Rosetta: without it the JIT cannot map its memory there, and the
# freshly built emulator stops while bootstrapping OTP with
# {failed_to_start_child,user,nouser}. It changes how the build's own Erlang
# VMs map JIT code, not what they compile, so the artifacts are the same
# with or without it; on an x86-64 host it is harmless.
#
# Environment: JOBS, the number of parallel make jobs (default: every CPU).
set -euo pipefail

OPENSSL_VERSION=3.5.9

# SHA-256 of every file this script downloads. Take each value from its
# publisher (the SHA256.txt asset of the OTP GitHub release, the .sha256 file
# beside the OpenSSL tarball, the builds.txt index on builds.hex.pm for
# Elixir) and check that the download matches before adding it.
pinned_sha256() {
  case $1 in
    otp_src_29.1.1.tar.gz) echo 054e0143e39c780e091107fc9b345792a9c1a55f6bac1eca1c1101510fc06bf6 ;;
    openssl-3.5.9.tar.gz) echo 603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a ;;
    v1.20.4-otp-29.zip) echo 7863c546cda13fecc949e562e326042451dacf8fd8698a36783cb71eeb223b46 ;;
    *) return 1 ;;
  esac
}

root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)
script="$root/scripts/$(basename "$0")"

die() {
  echo "build-static-otp: $*" >&2
  exit 1
}

usage() {
  echo "usage: scripts/build-static-otp.sh [--verify] PREFIX | --check-pins" >&2
  exit 2
}

tool_version() {
  awk -v tool="$1" '$1 == tool { print $2 }' "$root/.tool-versions"
}

otp_version=$(tool_version erlang)
elixir_version=$(tool_version elixir)
[ -n "$otp_version" ] || die "no erlang version in .tool-versions"
[ -n "$elixir_version" ] || die "no elixir version in .tool-versions"

otp_file="otp_src_$otp_version.tar.gz"
openssl_file="openssl-$OPENSSL_VERSION.tar.gz"
elixir_file="v$elixir_version.zip"

check_pins() {
  local missing=0 file
  # The precompiled Elixir is built for one OTP major and must match.
  case $elixir_version in
    *-otp-"${otp_version%%.*}") ;;
    *) die "elixir $elixir_version in .tool-versions is not built for OTP ${otp_version%%.*}" ;;
  esac
  for file in "$otp_file" "$openssl_file" "$elixir_file"; do
    if ! pinned_sha256 "$file" >/dev/null; then
      echo "build-static-otp: no pinned SHA-256 for $file; add its published checksum to pinned_sha256 in scripts/build-static-otp.sh" >&2
      missing=1
    fi
  done
  return "$missing"
}

need() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required; see the header of scripts/build-static-otp.sh"
  done
}

# The first line a tool prints for --version, or "missing". Captured rather
# than piped into head, which could end the tool with SIGPIPE under pipefail.
first_version_line() {
  local out
  out=$("$1" --version 2>/dev/null) || out=missing
  echo "${out%%$'\n'*}"
}

# The inputs a build depends on. A PREFIX whose BUILD-INFO says the same is
# that build. The compiler and C library are listed because the image's
# packages, not this script, choose them, and a different compiler gives
# different native libraries.
build_info() {
  local file
  for file in "$otp_file" "$openssl_file" "$elixir_file"; do
    echo "$file $(pinned_sha256 "$file")"
  done
  echo "architecture $(uname -m)"
  echo "compiler $(first_version_line cc)"
  echo "libc $(first_version_line ldd)"
  echo "script $(sha256sum "$script" | cut -d' ' -f1)"
}

fetch() {
  local url=$1 file=$2 expected actual
  expected=$(pinned_sha256 "$file") || die "no pinned SHA-256 for $file"
  echo "==> downloading $file"
  curl --proto '=https' --proto-redir '=https' --tlsv1.2 --fail --silent --show-error \
    --location --retry 3 --output "$work/$file" "$url"
  actual=$(sha256sum "$work/$file" | cut -d' ' -f1)
  [ "$actual" = "$expected" ] || die "$file has SHA-256 $actual, but $expected is pinned"
}

# Runs a long build step with its output in a log, shown only when it fails.
# The steps chain with && because errexit does not apply to a function
# called as an `if` condition.
logged() {
  local name=$1
  shift
  echo "==> building $name"
  if ! "$@" >"$work/$name.log" 2>&1; then
    tail -n 80 "$work/$name.log" >&2
    die "building $name failed; the end of its log is above"
  fi
}

build_openssl() {
  # OpenSSL dates its build from SOURCE_DATE_EPOCH when set; its release's
  # own timestamp keeps that string the same on every rebuild.
  (cd "$work/openssl-$OPENSSL_VERSION" &&
    SOURCE_DATE_EPOCH=$(stat -c %Y VERSION.dat) &&
    export SOURCE_DATE_EPOCH &&
    ./Configure "$openssl_target" no-shared no-tests no-docs -fPIC \
      --prefix="$prefix/openssl" --libdir=lib --openssldir=/etc/ssl &&
    make -j"$jobs" &&
    make install_sw)
}

build_otp() {
  (cd "$work/otp_src_$otp_version" &&
    LDFLAGS="-static-libstdc++ -static-libgcc" ./configure --prefix="$prefix/otp" \
      --enable-deterministic-build \
      --with-ssl="$prefix/openssl" --disable-dynamic-ssl-lib --without-termcap \
      --without-javac --without-wx --without-odbc --without-debugger --without-observer \
      --without-et --without-megaco --without-diameter --without-snmp &&
    make -j"$jobs" &&
    make install)
}

build() {
  need cc c++ make perl curl tar unzip stat sha256sum readelf objdump
  jobs=${JOBS:-$(nproc)}
  case $jobs in
    '' | *[!0-9]*) die "JOBS must be a number, not '$jobs'" ;;
  esac
  case $(uname -m) in
    x86_64) openssl_target=linux-x86_64 ;;
    aarch64) openssl_target=linux-aarch64 ;;
    *) die "no OpenSSL target for $(uname -m)" ;;
  esac

  work="$prefix/src"
  rm -rf "$work" "$prefix/openssl" "$prefix/otp" "$prefix/elixir" "$prefix/BUILD-INFO"
  mkdir -p "$work" "$prefix/elixir"
  trap 'rm -rf "$work"' EXIT

  fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/$openssl_file" "$openssl_file"
  fetch "https://github.com/erlang/otp/releases/download/OTP-$otp_version/$otp_file" "$otp_file"
  fetch "https://builds.hex.pm/builds/elixir/$elixir_file" "$elixir_file"

  tar -xzf "$work/$openssl_file" -C "$work"
  tar -xzf "$work/$otp_file" -C "$work"
  logged openssl build_openssl
  logged otp build_otp
  unzip -q "$work/$elixir_file" -d "$prefix/elixir"
}

# Proves PREFIX is the runtime this script promises: the pinned OTP, Elixir
# and OpenSSL, and no OTP binary that needs a library outside glibc.
verify() {
  local erl="$prefix/otp/bin/erl" release info elixir file lib needed bad=0 floor digest
  need readelf objdump
  [ -x "$erl" ] || die "$erl does not exist; build first"

  release=$(cat "$prefix"/otp/lib/erlang/releases/*/OTP_VERSION)
  [ "$release" = "$otp_version" ] || die "PREFIX holds OTP $release, not $otp_version"
  # Caught and halted either way: an -eval that raises leaves a -noshell VM
  # running, which would hang the build instead of failing it.
  info=$("$erl" -noshell -eval '
    try io:format("~ts~n", [element(3, hd(crypto:info_lib()))])
    catch Class:Reason -> io:format("crypto did not load: ~p~n", [{Class, Reason}])
    end,
    halt().')
  case $info in
    "OpenSSL $OPENSSL_VERSION "*) ;;
    *) die "crypto reports '$info', not OpenSSL $OPENSSL_VERSION" ;;
  esac
  elixir=$(PATH="$prefix/otp/bin:$PATH" "$prefix/elixir/bin/elixir" --short-version)
  [ "$elixir" = "${elixir_version%%-otp-*}" ] || die "PREFIX holds Elixir $elixir, not ${elixir_version%%-otp-*}"

  while IFS= read -r -d '' file; do
    readelf -h "$file" >/dev/null 2>&1 || continue
    needed=$(readelf -d "$file" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p')
    for lib in $needed; do
      case $lib in
        libc.so.6 | libm.so.6 | libpthread.so.0 | libdl.so.2 | librt.so.1 | libutil.so.1 | ld-linux-*.so.*) ;;
        *)
          echo "build-static-otp: ${file#"$prefix"/} needs $lib, which is not part of glibc" >&2
          bad=1
          ;;
      esac
    done
  done < <(find "$prefix/otp/lib/erlang" -type f \( -name '*.so' -o -perm -100 \) -print0)
  [ "$bad" -eq 0 ] || die "the runtime is not portable; see the libraries above"

  floor=$(objdump -T "$prefix"/otp/lib/erlang/erts-*/bin/beam.smp |
    grep -o 'GLIBC_[0-9][0-9.]*' | sort -u -V | tail -n 1 || true)
  echo "build-static-otp: OTP $release, Elixir $elixir, $info; needs only glibc (${floor:-no versioned symbols})"

  # What a release copies from this build into its identity: each OTP
  # application's modules (ebin/) and native files (priv/). Paths and
  # contents both count, in a fixed order.
  digest=$(cd "$prefix/otp/lib/erlang/lib" &&
    find . \( -path './*/ebin/*' -o -path './*/priv/*' \) -type f -print0 |
    LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | cut -d' ' -f1)
  echo "build-static-otp: OTP application digest $digest"
}

case ${1-} in
  --check-pins)
    [ "$#" -eq 1 ] || usage
    check_pins
    echo "build-static-otp: OTP $otp_version, Elixir $elixir_version and OpenSSL $OPENSSL_VERSION are pinned"
    ;;
  --verify)
    [ "$#" -eq 2 ] || usage
    [ "$(uname -s)" = Linux ] || die "verifies Linux builds only"
    prefix=$2
    check_pins
    verify
    ;;
  -* | '') usage ;;
  *)
    [ "$#" -eq 1 ] || usage
    [ "$(uname -s)" = Linux ] || die "builds the Linux runtime and must run on Linux"
    check_pins
    mkdir -p "$1"
    prefix=$(CDPATH='' cd "$1" && pwd -P)
    if [ -f "$prefix/BUILD-INFO" ] && [ "$(cat "$prefix/BUILD-INFO")" = "$(build_info)" ]; then
      echo "build-static-otp: reusing the build in $prefix"
    else
      build
    fi
    verify
    build_info >"$prefix/BUILD-INFO"
    echo "build-static-otp: add $prefix/otp/bin and $prefix/elixir/bin to PATH"
    ;;
esac
