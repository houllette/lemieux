#!/usr/bin/env bash
# Observe a fixed tree under several orders. Every attempt contributes to
# Temper, but a later pass cannot erase an earlier failure's exit status.
set -eu
trap 'exit 130' INT
trap 'exit 143' TERM
cd "$(dirname "$0")/.."

usage() {
  echo "Usage: scripts/check_flakes.sh [--runs 2..20] [--seed 0..999999] [--max-cases 1..64] [test/PATH_test.exs[:LINE] ...]"
}

fail() {
  echo "$1" >&2
  usage >&2
  exit 2
}

runs=3
seed=101
max_cases=4
while [ "$#" -gt 0 ]; do
  case "$1" in
    --runs|--seed|--max-cases)
      [ "$#" -ge 2 ] || fail "Missing value for $1"
      [[ "$2" =~ ^[0-9]{1,6}$ ]] || fail "Expected a decimal integer for $1"
      value=$((10#$2))
      case "$1" in
        --runs) runs=$value ;;
        --seed) seed=$value ;;
        --max-cases) max_cases=$value ;;
      esac
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    --*) fail "Unsupported option: $1 (only offline test paths are accepted)" ;;
    *) break ;;
  esac
done

(( runs >= 2 && runs <= 20 )) || fail "--runs must be between 2 and 20"
(( max_cases >= 1 && max_cases <= 64 )) || fail "--max-cases must be between 1 and 64"
for selector in "$@"; do
  file=$selector
  if [[ "$selector" == *:* ]]; then
    file=${selector%:*}
    line=${selector##*:}
    [[ "$line" =~ ^[0-9]+$ ]] || fail "Invalid test line: $selector"
  fi
  case "$file" in
    test/*_test.exs) [ -f "$file" ] || fail "Test file does not exist: $file" ;;
    *) fail "Expected a test/PATH_test.exs[:LINE] selector: $selector" ;;
  esac
done

# Even a shell that previously opted into spending cannot make this runner
# execute a paid test selected by line. The suite's skip guard stays in force.
unset LEMIEUX_ALLOW_SPEND
export MIX_ENV=test
status=0
for (( attempt=0; attempt<runs; attempt++ )); do
  current_seed=$((seed + attempt))
  echo "Flake observation $((attempt + 1))/$runs: seed=$current_seed max_cases=$max_cases"
  if ! mix test --warnings-as-errors --seed "$current_seed" --max-cases "$max_cases" "$@"; then
    status=1
  fi
done
if ! mix temper.report; then
  status=1
fi
exit "$status"
