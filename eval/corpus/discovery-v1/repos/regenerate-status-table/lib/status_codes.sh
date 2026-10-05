# GENERATED FILE - do not edit by hand.
# Source: src/status_codes.tsv. Regenerate with: sh scripts/gen.sh
# entries: 8
status_name() {
  case "$1" in
    200) printf '%s\n' "OK" ;;
    201) printf '%s\n' "Created" ;;
    204) printf '%s\n' "No Content" ;;
    301) printf '%s\n' "Moved Permanently" ;;
    400) printf '%s\n' "Bad Request" ;;
    404) printf '%s\n' "Not Found" ;;
    500) printf '%s\n' "Internal Server Error" ;;
    503) printf '%s\n' "Service Unavailable" ;;
    *) printf 'unknown status %s\n' "$1" >&2; return 1 ;;
  esac
}
