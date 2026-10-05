# User lookups against data/users.tsv (id, login, name, team).

# fetch_user LOGIN
# Prints the tab-separated record for LOGIN, or fails when it is unknown.
fetch_user() {
  login=$1
  record=$(awk -F '\t' -v login="$login" '$2 == login { print; found = 1 } END { exit !found }' "${USERS_FILE:-data/users.tsv}") || {
    echo "unknown user: $login" >&2
    return 1
  }
  printf '%s\n' "$record"
}
