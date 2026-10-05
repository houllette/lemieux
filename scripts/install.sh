#!/bin/sh
# Bootstraps lmx from the latest GitHub release. Fetches install.py,
# SHA256SUMS and SHA256SUMS.sig, checks install.py against SHA256SUMS, then
# passes both files to install.py, which verifies the signature with the
# release key pinned in it before it installs anything.
#
# This first download trusts TLS and GitHub: a script that fetched its own
# verifier could not check that verifier. To check one yourself first, see
# "Verify a download" in docs/releases.md. Needs curl and Python 3.8+.
set -eu

# Python 3.8 or newer: LMX_PYTHON when it is set, and then nothing else, or
# else the first one on PATH, so distributions whose python3 is older
# (openSUSE Leap's 3.6) can still install.
lmx_python_usable() {
  command -v "$1" >/dev/null 2>&1 &&
    "$1" -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1
}
lmx_python=
if [ -n "${LMX_PYTHON:-}" ]; then
  if ! lmx_python_usable "$LMX_PYTHON"; then
    echo "LMX_PYTHON is set to $LMX_PYTHON, which is not a Python 3.8 or newer that runs here. Point it at one, or unset it to use the first suitable python3 on PATH." >&2
    exit 1
  fi
  lmx_python=$LMX_PYTHON
else
  for lmx_candidate in python3 python3.15 python3.14 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
    if lmx_python_usable "$lmx_candidate"; then
      lmx_python=$lmx_candidate
      break
    fi
  done
fi
if [ -z "$lmx_python" ]; then
  echo 'lmx installation needs Python 3.8 or newer. Install python3 from your distribution (on macOS: xcode-select --install), or set LMX_PYTHON to its path.' >&2
  exit 1
fi
command -v curl >/dev/null 2>&1 || { echo 'lmx installation needs curl' >&2; exit 1; }

lmx_bootstrap=$(mktemp -d)
trap 'rm -rf "$lmx_bootstrap"' EXIT
trap 'exit 1' HUP INT TERM
lmx_origin=https://github.com/houllette/lemieux/releases/latest/download
for lmx_asset in install.py SHA256SUMS SHA256SUMS.sig; do
  if ! curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
    "$lmx_origin/$lmx_asset" -o "$lmx_bootstrap/$lmx_asset"; then
    echo "lmx installation could not download $lmx_asset from the latest release." >&2
    [ "$lmx_asset" != SHA256SUMS.sig ] || echo 'A release without SHA256SUMS.sig is unsigned, and lmx does not install unsigned releases.' >&2
    exit 1
  fi
done

# Python rather than awk and sha256sum, which slim container images may lack.
"$lmx_python" -c '
import hashlib, sys
listed = [line.split()[0] for line in open(sys.argv[1] + "/SHA256SUMS")
          if [part.lstrip("*") for part in line.split()[1:]] == ["install.py"]]
actual = hashlib.sha256(open(sys.argv[1] + "/install.py", "rb").read()).hexdigest()
sys.exit(0 if listed == [actual] else 1)' "$lmx_bootstrap" || { echo 'installer checksum mismatch' >&2; exit 1; }
"$lmx_python" "$lmx_bootstrap/install.py" --checksums "$lmx_bootstrap/SHA256SUMS" --signature "$lmx_bootstrap/SHA256SUMS.sig" "$@"
