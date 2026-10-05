# Bulk import built on the storage layer.

# import_lines: reads KEY=VALUE lines on stdin.
import_lines() {
  while IFS= read -r line; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    store_put "$key" "$value"
  done
}
