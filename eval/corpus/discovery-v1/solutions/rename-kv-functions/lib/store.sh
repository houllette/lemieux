# Storage layer for kv. The data file is tab-separated "key<TAB>value".

store_file() { printf '%s\n' "${STORE_FILE:-data/store.tsv}"; }

# kv_get KEY
kv_get() {
  awk -F '\t' -v key="$1" '$1 == key { print $2; found = 1 } END { exit !found }' "$(store_file)"
}

# kv_put KEY VALUE
kv_put() {
  file=$(store_file)
  [ -f "$file" ] || : > "$file"
  { awk -F '\t' -v key="$1" '$1 != key' "$file"; printf '%s\t%s\n' "$1" "$2"; } > "$file.tmp"
  mv "$file.tmp" "$file"
}

# kv_del KEY
kv_del() {
  file=$(store_file)
  [ -f "$file" ] || return 0
  awk -F '\t' -v key="$1" '$1 != key' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
}

# kv_keys
kv_keys() {
  file=$(store_file)
  [ -f "$file" ] || return 0
  cut -f 1 "$file" | sort
}
