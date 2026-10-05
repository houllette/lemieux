# Shared test helpers. Sourced by tests/run.sh after lib/store.sh.

fail() { printf 'FAIL: %s\n' "$1"; exit 1; }

# seed_store: fills the temporary store with known data.
seed_store() {
  kv_put colour blue
  kv_put size large
  kv_put shape round
}
