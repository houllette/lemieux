# Exit helpers. Site overrides in lib/codes.local.sh win over lib/codes.sh.
. lib/codes.sh
if [ -f lib/codes.local.sh ]; then
  . lib/codes.local.sh
fi

exit_ok() { exit "$EXIT_OK"; }
exit_usage() { exit "$EXIT_USAGE"; }
exit_partial() { exit "$EXIT_PARTIAL"; }
