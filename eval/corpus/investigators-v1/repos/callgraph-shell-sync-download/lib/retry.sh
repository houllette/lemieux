# retry <attempts> <command...>
retry() {
  attempts=$1; shift
  n=1
  until "$@"; do
    [ "$n" -ge "$attempts" ] && return 1
    n=$((n + 1))
    sleep "$n"
  done
}
