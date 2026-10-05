# sync_records <dry-run> prints the number of failed records.
sync_records() {
  failed=0
  for record in records/*.json; do
    if ! push_record "$record" "$1"; then
      failed=$((failed + 1))
    fi
  done
  echo "$failed"
}

push_record() {
  [ "$2" = 1 ] && return 0
  curl -fsS -X PUT "https://store.example.com/records/$(basename "$1" .json)" --data-binary "@$1" >/dev/null
}
