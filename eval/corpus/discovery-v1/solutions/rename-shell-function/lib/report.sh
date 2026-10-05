# Human-readable rendering of user records.

# describe_user LOGIN
# Prints "NAME (TEAM)" for LOGIN.
describe_user() {
  record=$(load_user "$1") || return 1
  name=$(printf '%s\n' "$record" | cut -f 3)
  team=$(printf '%s\n' "$record" | cut -f 4)
  printf '%s (%s)\n' "$name" "$team"
}
