# Audit trail helpers. See docs/API.md for which entry point to use.

audit_path() { printf '%s\n' "${AUDIT_LOG:-var/audit.log}"; }

# audit_write LINE (internal)
audit_write() {
  log=$(audit_path)
  mkdir -p "$(dirname "$log")"
  printf '%s\n' "$1" >> "$log"
}

# audit_log MESSAGE (deprecated; pre-2025 format)
audit_log() {
  audit_write "[LEGACY] $(date -u +%Y-%m-%d) $1"
}

# audit_emit CATEGORY MESSAGE
audit_emit() {
  log=$(audit_path)
  seq_file="$log.seq"
  mkdir -p "$(dirname "$log")"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  seq=$((seq + 1))
  printf '%s\n' "$seq" > "$seq_file"
  audit_write "$(printf '%04d %s %s' "$seq" "$1" "$2")"
}
