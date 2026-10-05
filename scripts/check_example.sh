#!/bin/sh
# Run the checks CI runs for example projects, against this checkout.
#
#     scripts/check_example.sh NAME...        (e.g. verifier review security)
#
# NAME is a project under examples/extensions/, or under dist/lmx/extensions/
# for an extension the lmx binary bundles (jev_compaction); examples/ is
# searched first. Each is its own Mix project, and by default several resolve
# Lemieux from a pinned Git revision, so they are pointed at this checkout
# instead. Without that, an example could keep passing against an old
# revision while the library it documents moved on. Every example runs
# without a personal configuration file, so nothing on this machine changes
# the result.
#
# The checks run in MIX_ENV=test, as they do in CI. `mix cmd` does not hand
# an alias's preferred environment to its children, so under `mix
# precommit.full` the `check` aliases (which end in `test`) used to start in
# :dev and stop with "mix test is running in the dev environment", a failure
# CI never showed because its workflows export MIX_ENV=test. One environment
# also compiles each example's dependencies once instead of twice. Only the
# tutorial's bundle build runs in :dev, as the tutorial runs it.
set -eu
root=$(CDPATH='' cd "$(dirname "$0")/.." && pwd -P)

if [ "$#" -eq 0 ]; then
  echo "usage: scripts/check_example.sh NAME..." >&2
  exit 2
fi

for name in "$@"; do
  dir=""
  for base in examples/extensions dist/lmx/extensions; do
    if [ -f "$root/$base/$name/mix.exs" ]; then
      dir="$root/$base/$name"
      break
    fi
  done
  if [ -z "$dir" ]; then
    echo "no example project named $name in examples/extensions or dist/lmx/extensions" >&2
    exit 2
  fi

  echo "==> ${dir#"$root"/}"
  (
    cd "$dir"
    export LEMIEUX_EXTENSION_BASE="$root" LMX_CONFIG=none MIX_ENV=test

    # `deps.get` against this checkout writes a mix.lock that pins a local
    # path. On the way out the example's own lock is put back, or the new one
    # removed, so a local run never leaves a lock that must not be committed.
    lock_backup=$(mktemp "${TMPDIR:-/tmp}/lemieux-lock.XXXXXXXX")
    had_lock=false
    if [ -f mix.lock ]; then
      cp mix.lock "$lock_backup"
      had_lock=true
    fi
    scratch=""
    # Invoked by the EXIT trap below, which ShellCheck cannot see: 0.9 reports
    # that as unreachable code (SC2317), 0.10 and later as an unused function.
    # shellcheck disable=SC2317,SC2329
    cleanup() {
      if [ "$had_lock" = true ]; then cp "$lock_backup" mix.lock; else rm -f mix.lock; fi
      rm -f "$lock_backup"
      if [ -n "$scratch" ]; then rm -rf "$scratch"; fi
    }
    trap cleanup EXIT

    mix deps.get

    case $name in
      # These two define their own `check` alias, which is the contract.
      computer_use | jev_compaction)
        mix check
        ;;
      # The tutorial also proves the documented bundle build still works,
      # run the way the tutorial runs it: from a plain shell, so in :dev.
      hello)
        mix format --check-formatted
        mix test --warnings-as-errors
        scratch=$(mktemp -d "${TMPDIR:-/tmp}/lemieux-hello.XXXXXXXX")
        MIX_ENV=dev mix lmx.extension.build --name hello --output "$scratch/hello"
        ;;
      *)
        if [ -f .formatter.exs ]; then mix format --check-formatted; fi
        mix compile --warnings-as-errors
        if [ -d test ]; then mix test --warnings-as-errors; fi
        ;;
    esac
  )
done
