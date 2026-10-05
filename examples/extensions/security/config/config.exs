import Config

# The only hosts `nmap_scan` may scan (`SecurityExample.Scope`). A call naming
# any other address is denied before Nmap runs, and the model is told why.
# Add an address only for a host you are authorized to scan; entries are
# single IPv4 addresses. A host application that depends on this package sets
# the same key in its own configuration, and with none set, nothing is scanned.
config :security_example, scan_targets: ["127.0.0.1"]
