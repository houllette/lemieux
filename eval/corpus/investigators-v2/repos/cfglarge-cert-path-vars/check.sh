#!/bin/sh
# Grader for cfglarge-cert-path-vars: every fixture file must be unchanged and the
# reported answer (argv 1) must contain each expected fact.
set -u
fail() { printf 'check failed: %s\n' "$1"; exit 1; }
answer=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
verify() {
  [ -f "$1" ] || fail "$1 is missing"
  actual=$(cksum < "$1" | awk '{print $1}')
  [ "$actual" = "$2" ] || fail "$1 was modified"
}
expect() {
  label=$1; shift
  for enc in "$@"; do
    tok=$(printf "$enc")
    case "$answer" in *"$tok"*) return 0 ;; esac
  done
  fail "answer is missing expected fact $label"
}
verify README.md 689244122
verify config/archive/edge-lite-3.conf 150208882
verify config/archive/ledger-4.conf 2851257266
verify config/archive/search-2.conf 3683927414
verify config/archive/worker-batch-0.conf 2345973646
verify config/archive/worker-batch-5.conf 3761367821
verify config/archive/worker-stream-1.conf 4030972730
verify config/includes/apac-tuning.conf 1576149525
verify config/includes/audit-tuning.conf 1812755847
verify config/includes/batch-tuning.conf 3545585299
verify config/includes/cache-defaults.conf 3884717124
verify config/includes/cold-path.conf 4159404684
verify config/includes/compat-2025.conf 1828389260
verify config/includes/eu-tuning.conf 3623413884
verify config/includes/feature-defaults.conf 1795426222
verify config/includes/hot-path.conf 2679560426
verify config/includes/limits-defaults.conf 973006493
verify config/includes/logging-defaults.conf 1939868279
verify config/includes/pools.conf 2036984760
verify config/includes/queue-defaults.conf 449896669
verify config/includes/timeouts.conf 666512043
verify config/includes/tls-defaults.conf 226116077
verify config/includes/us-tuning.conf 3539031424
verify config/overlays/apac-latency.conf 1512102254
verify config/overlays/beta-cohort.conf 3880183536
verify config/overlays/eu-privacy.conf 3009141913
verify config/overlays/high-memory.conf 2612493227
verify config/overlays/ledger-strict.conf 1669800075
verify config/overlays/legacy-clients.conf 272607823
verify config/overlays/low-memory.conf 264395709
verify config/overlays/maintenance.conf 3750847518
verify config/overlays/peak-season.conf 1653493004
verify config/overlays/search-experiment.conf 1902186005
verify config/sinks/apac-collector.conf 3067555646
verify config/sinks/archive.conf 3619893996
verify config/sinks/debug.conf 6528264
verify config/sinks/eu-collector.conf 2244250662
verify config/sinks/legacy.conf 2794888042
verify config/sinks/primary.conf 987184518
verify config/sinks/secondary.conf 2751738598
verify config/sinks/us-collector.conf 277475885
verify deploy/canary/apac-south/env.list 3243940170
verify deploy/canary/apac-south/target.conf 3788799990
verify deploy/canary/eu-central/env.list 3391277801
verify deploy/canary/eu-central/target.conf 616769425
verify deploy/canary/eu-west/env.list 607129563
verify deploy/canary/eu-west/target.conf 4109196680
verify deploy/canary/us-east/env.list 2406447881
verify deploy/canary/us-east/target.conf 1627482493
verify deploy/dev/apac-south/env.list 31359647
verify deploy/dev/apac-south/target.conf 3349927432
verify deploy/dev/eu-central/env.list 3005297974
verify deploy/dev/eu-central/target.conf 3705064236
verify deploy/dev/eu-west/env.list 617650429
verify deploy/dev/eu-west/target.conf 1366860256
verify deploy/dev/us-east/env.list 3781650242
verify deploy/dev/us-east/target.conf 1993249312
verify deploy/prod/apac-south/env.list 3916005110
verify deploy/prod/apac-south/target.conf 2157795036
verify deploy/prod/eu-central/env.list 4167892336
verify deploy/prod/eu-central/target.conf 2069233829
verify deploy/prod/eu-west/env.list 1114608561
verify deploy/prod/eu-west/target.conf 1705976294
verify deploy/prod/us-east/env.list 2426108441
verify deploy/prod/us-east/target.conf 1795509148
verify deploy/staging/apac-south/env.list 384540964
verify deploy/staging/apac-south/target.conf 2604025926
verify deploy/staging/eu-central/env.list 2741061513
verify deploy/staging/eu-central/target.conf 2980034604
verify deploy/staging/eu-west/env.list 1053398437
verify deploy/staging/eu-west/target.conf 3167421722
verify deploy/staging/us-east/env.list 1057828163
verify deploy/staging/us-east/target.conf 2326697885
verify docs/keys-reference.md 1697252819
verify docs/rollout-notes.md 2775437369
verify docs/rollouts/canary/apac-south.md 2492601729
verify docs/rollouts/canary/eu-central.md 1689961494
verify docs/rollouts/canary/eu-west.md 3097099939
verify docs/rollouts/canary/us-east.md 2740068247
verify docs/rollouts/dev/apac-south.md 2631788000
verify docs/rollouts/dev/eu-central.md 903671195
verify docs/rollouts/dev/eu-west.md 563002375
verify docs/rollouts/dev/us-east.md 2704687846
verify docs/rollouts/prod/apac-south.md 1260286516
verify docs/rollouts/prod/eu-central.md 4151260257
verify docs/rollouts/prod/eu-west.md 1472287474
verify docs/rollouts/prod/us-east.md 4207698396
verify docs/rollouts/staging/apac-south.md 3295929570
verify docs/rollouts/staging/eu-central.md 3906786478
verify docs/rollouts/staging/eu-west.md 3068703151
verify docs/rollouts/staging/us-east.md 590458539
verify history/changes-2026-03.md 46687987
verify history/changes-2026-04.md 4079056422
verify history/changes-2026-05.md 4273373772
verify history/changes-2026-06.md 2120525843
verify history/changes-2026-07.md 3340097137
verify history/changes-2026-08.md 1412326423
verify inventory/hosts.tsv 1197440731
verify policy/canary/locked.conf 2690395329
verify policy/dev/locked.conf 4216569993
verify policy/prod/locked.conf 3549825411
verify policy/staging/locked.conf 2647210004
verify profiles/admin.conf 327376773
verify profiles/api-internal.conf 1215174259
verify profiles/api-public.conf 2424278733
verify profiles/api.conf 2379060148
verify profiles/base.conf 2172856780
verify profiles/billing-nightly.conf 1396901236
verify profiles/billing.conf 2356447973
verify profiles/catalog-static.conf 3433589880
verify profiles/catalog.conf 737577624
verify profiles/edge-lite.conf 1270846873
verify profiles/edge.conf 2152996372
verify profiles/export-bulk.conf 1711798429
verify profiles/export.conf 4021778993
verify profiles/gateway-apac.conf 352882232
verify profiles/gateway-eu.conf 3156765094
verify profiles/gateway-us.conf 3309795247
verify profiles/gateway.conf 1219581583
verify profiles/ledger-audit.conf 3121028683
verify profiles/ledger.conf 3450757876
verify profiles/metrics-sampled.conf 2989598963
verify profiles/metrics.conf 393455576
verify profiles/search-warm.conf 1609247024
verify profiles/search.conf 2603974819
verify profiles/service.conf 3421375234
verify profiles/web-cold.conf 911075100
verify profiles/web-hot.conf 809651538
verify profiles/web.conf 1648245892
verify profiles/worker-batch.conf 204545073
verify profiles/worker-stream.conf 4095709575
verify profiles/worker.conf 637977612
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\057\145\164\143\057\155\145\163\150\057\143\145\162\164\163\057\154\145\147\141\143\171\057\147\141\164\145\167\141\171\055\165\163\145\141\163\164\061\055\143\157\155\160\141\164\056\160\145\155'
echo "report ok"
