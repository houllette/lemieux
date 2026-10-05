#!/bin/sh
set -eu
# What the person's commands inherit is the environment they started lmx
# with, not the VM's (Lmx.CLI, "What the commands lmx starts inherit"):
# erlexec puts the release's ERTS first on PATH, where the person's own erl,
# elixir and mix then failed with "cannot get bootfile", and it, the release
# script and this script set BINDIR, ROOTDIR, EMU, PROGNAME, RELEASE_* and
# ERL_CRASH_DUMP. So before anything here changes them, record PATH and
# the value of each of those the person set; Lmx.CLI.inherited/1 reads
# them back. Names come from `env`, which may also print a fragment of a
# value with a newline in it; the pattern admits only a variable's name,
# and only one that is set is recorded.
if [ "${PATH+set}" = set ]; then export LMX_PARENT_PATH="$PATH"; fi
for lmx_name in BINDIR ROOTDIR EMU PROGNAME ERL_CRASH_DUMP ELIXIR_ERL_OPTIONS $(env | sed -n 's/^\(RELEASE_[A-Za-z0-9_]*\)=.*/\1/p'); do
  eval "lmx_set=\${$lmx_name+set}"
  if [ "$lmx_set" = set ]; then eval "export LMX_PARENT__$lmx_name=\"\$$lmx_name\""; fi
done
# Register before any BEAM starts reading a mutable OTP workspace. The same
# exclusive lock protects activation and installer pointer replacement. A lease
# acquired only inside Lmx.Boot leaves the entire VM startup window unprotected.
lmx_lease=''
lmx_lock_owned=''
lmx_child=''
lmx_tty=''
lmx_cleanup() {
  [ -z "${LMX_ARGV_FILE:-}" ] || rm -f "$LMX_ARGV_FILE"
  if [ -n "$lmx_lease" ]; then
    # The lease is transferred to the VM during boot. Keep it if a signal
    # interrupted waiting and the VM is still alive.
    lmx_pid=$(cat "$lmx_lease" 2>/dev/null || true)
    if [ "$lmx_pid" = "$$" ] || ! kill -0 "$lmx_pid" 2>/dev/null; then rm -f "$lmx_lease"; fi
  fi
  [ -z "$lmx_lock_owned" ] || rm -f "$lmx_lock_owned"
}
trap lmx_cleanup EXIT
# A VM that dies without leaving its full screen (kill -9, a crash) left the
# shell in raw mode inside the alternate screen, with mouse reporting on and
# the cursor hidden. This script outlives the VM, so it puts the terminal
# back, but only when the terminal's settings show that something changed
# them: an ordinary failing `lmx run` never touched the terminal, and
# ESC[?1049l outside the alternate screen moves the cursor on some terminals.
lmx_restore_terminal() {
  [ -n "$lmx_tty" ] || return 0
  lmx_now=$(stty -g 2>/dev/null) || return 0
  [ "$lmx_now" != "$lmx_tty" ] || return 0
  stty "$lmx_tty" 2>/dev/null || true
  printf '\033[?1000l\033[?1002l\033[?1003l\033[?1006l\033[?1015l\033[?1004l\033[?2004l\033[?25h\033[?1049l'
}
# The VM ignores Ctrl-C itself (+Bi in vm.args) and starts with SIGHUP
# ignored (below), so Ctrl-C, a closed terminal and `kill` all reach it as the
# SIGTERM forwarded here, which cancels the running turn before it stops
# (Lmx.Boot); the launcher then exits with the status of its own signal.
lmx_signal() {
  if [ -n "$lmx_child" ]; then kill -TERM "$lmx_child" 2>/dev/null || true; wait "$lmx_child" 2>/dev/null || true; fi
  lmx_restore_terminal
  exit "$1"
}
trap 'lmx_signal 129' HUP
trap 'lmx_signal 130' INT
trap 'lmx_signal 143' TERM
if [ -n "${LMX_INSTALL_HOME:-}" ]; then
  if [ ! -d "$LMX_INSTALL_HOME" ]; then
    echo "lmx: the installation at $LMX_INSTALL_HOME is missing; reinstall it with install.sh" >&2
    exit 1
  fi
  # Installs are per user. Another user's installation used to spin here for
  # 150 seconds, mistaking "permission denied" for a busy lock, and then
  # blame an update.
  if [ ! -w "$LMX_INSTALL_HOME" ]; then
    if [ -O "$LMX_INSTALL_HOME" ]; then
      echo "lmx: $LMX_INSTALL_HOME is not writable; lmx records each launch there" >&2
    else
      echo 'lmx: this installation belongs to another user; reinstall it as yourself with install.sh' >&2
    fi
    exit 1
  fi
  lmx_lock=$LMX_INSTALL_HOME/.update-lock
  lmx_attempt=0
  lmx_absent=0
  until (set -C; printf '%s' "$$" > "$lmx_lock") 2>/dev/null; do
    # Only an existing lock means another launch or an update holds it. A
    # failure with no lock in place (a permission problem, a read-only file
    # system) will not clear by waiting. A lock released between the two
    # checks gets two immediate retries.
    if [ ! -e "$lmx_lock" ] && [ ! -L "$lmx_lock" ]; then
      lmx_absent=$((lmx_absent + 1))
      if [ "$lmx_absent" -ge 3 ]; then
        echo "lmx: cannot create $lmx_lock; check that you own this installation and can write to it" >&2
        exit 1
      fi
      continue
    fi
    lmx_absent=0
    lmx_attempt=$((lmx_attempt + 1))
    if [ "$lmx_attempt" -ge 150 ]; then
      echo 'lmx: installation is busy; retry when the update completes. See docs/support.md for interrupted-install recovery.' >&2
      exit 1
    fi
    sleep 1
  done
  lmx_lock_owned=$lmx_lock
  mkdir -p "$LMX_INSTALL_HOME/running"
  lmx_lease=$(mktemp "$LMX_INSTALL_HOME/running/$$-XXXXXXXX")
  printf '%s' "$$" > "$lmx_lease"
  export LMX_LEASE_FILE="$lmx_lease"
  rm -f "$lmx_lock"
  lmx_lock_owned=''
fi
lmx_self=$0
while [ -L "$lmx_self" ]; do
  lmx_link=$(readlink "$lmx_self")
  case $lmx_link in /*) lmx_self=$lmx_link ;; *) lmx_self=$(dirname "$lmx_self")/$lmx_link ;; esac
done
LMX_RELEASE_ROOT=$(CDPATH='' cd "$(dirname "$lmx_self")/.." && pwd -P)
export LMX_RELEASE_ROOT
LMX_ARGV_FILE=$(mktemp "${TMPDIR:-/tmp}/lmx-args.XXXXXXXX")
export LMX_ARGV_FILE
if [ "$#" -gt 0 ]; then printf '%s\000' "$@" > "$LMX_ARGV_FILE"; fi
# Each CLI owns a node, with no distribution socket. Updates use local SASL calls.
export RELEASE_DISTRIBUTION=none
# File names are UTF-8 whatever the locale says. vm.args says +fnu for the
# VM a command runs in, but the release script also boots a short-lived VM
# of its own on the first start after an install (Castle's preboot, which
# writes releases/RELEASES) without vm.args, and under a C or POSIX locale
# (containers, CI, `ssh host lmx`) that VM printed Elixir's "native name
# encoding of latin1" warning on the person's first command. Every VM the
# release script starts reads ELIXIR_ERL_OPTIONS. The person's own value
# stays after +fnu, and the commands the agent runs get it back unchanged
# (recorded above).
export ELIXIR_ERL_OPTIONS="+fnu${ELIXIR_ERL_OPTIONS:+ $ELIXIR_ERL_OPTIONS}"
# ERTS writes erl_crash.dump into the current directory, which is the
# person's project, and a dump holds whatever the VM held: provider keys and
# transcript text. Dumps go to the private state directory instead. ERTS
# reads the variable from the VM's environment when it crashes, so it stays
# exported; the commands the agent runs do not inherit it (recorded above),
# so a program of the person's that crashes leaves its dump where it would
# without lmx.
if [ -z "${ERL_CRASH_DUMP:-}" ] && [ -n "${LMX_HOME:-${HOME:-}}" ]; then
  lmx_crash_dir=${LMX_HOME:-$HOME/.lmx}/crash
  if (umask 077 && mkdir -p "$lmx_crash_dir" && chmod 700 "$lmx_crash_dir") 2>/dev/null; then
    export ERL_CRASH_DUMP="$lmx_crash_dir/erl_crash.dump"
  fi
fi
# The VM watches this pid and stops when the launcher is gone: SIGKILL to the
# launcher alone (subprocess timeouts, timeout -s KILL) used to leave the VM
# running the turn, requests and tools and all, with nobody attached. It
# stops as it would on the SIGTERM this script forwards, so the terminal UI
# still leaves its screen: a killed launcher never runs lmx_restore_terminal.
LMX_LAUNCHER_PID=$$
export LMX_LAUNCHER_PID
if [ -t 0 ] && [ -t 1 ]; then lmx_tty=$(stty -g 2>/dev/null || true); fi
# Backgrounded so the traps above can forward signals to the VM. A
# non-interactive shell gives an asynchronous command /dev/null as standard
# input, which silently discarded every prompt or answer piped to `lmx`. POSIX
# applies that /dev/null before the command's own redirections, so `<&0` on
# the command only duplicates /dev/null under dash (Ubuntu's /bin/sh), while
# bash happens to accept it. The launcher's input is copied to descriptor 3
# first, and the VM reads that.
#
# The subshell ignores SIGHUP for the VM alone. A closed terminal sends SIGHUP
# to the whole foreground process group, the VM included, and the VM's
# default for it is to die at once: nothing recorded as cancelled, and the
# agent's running command, in a session of its own, left running. Ignored
# there, a hangup reaches the VM only as the SIGTERM the trap above forwards.
# The VM does not handle SIGHUP itself because that would override `nohup lmx`.
# Commands the agent runs inherit the ignored SIGHUP, as under nohup; each runs
# in a session of its own, which no terminal hangup reaches anyway.
exec 3<&0
(trap '' HUP; exec "$LMX_RELEASE_ROOT/bin/lmx-release" start) <&3 3<&- &
exec 3<&-
lmx_child=$!
lmx_status=0
# bash reports a background job killed by a signal ("line N: PID Killed: 9
# ... lmx-release start") on the wait's standard error, over the screen it
# is about to restore; the status says the same thing.
wait "$lmx_child" 2>/dev/null || lmx_status=$?
lmx_restore_terminal
exit "$lmx_status"
