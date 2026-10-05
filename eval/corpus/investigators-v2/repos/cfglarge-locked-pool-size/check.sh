#!/bin/sh
# Grader for cfglarge-locked-pool-size: every fixture file must be unchanged and the
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
verify config/archive/base-1.conf 4087105082
verify config/archive/edge-3.conf 1104526208
verify config/archive/export-bulk-5.conf 3715861794
verify config/archive/search-0.conf 1319769814
verify config/archive/service-2.conf 3777807436
verify config/archive/web-4.conf 3461689794
verify config/includes/apac-tuning.conf 73835899
verify config/includes/audit-tuning.conf 1626642581
verify config/includes/batch-tuning.conf 1529302167
verify config/includes/cache-defaults.conf 325751672
verify config/includes/cold-path.conf 2306468026
verify config/includes/compat-2025.conf 585854633
verify config/includes/eu-tuning.conf 3623796008
verify config/includes/feature-defaults.conf 2035539900
verify config/includes/hot-path.conf 3097220873
verify config/includes/limits-defaults.conf 3887808943
verify config/includes/logging-defaults.conf 1844526996
verify config/includes/pools.conf 1807422613
verify config/includes/queue-defaults.conf 1841515748
verify config/includes/timeouts.conf 936387206
verify config/includes/tls-defaults.conf 3813064774
verify config/includes/us-tuning.conf 2900998385
verify config/overlays/apac-latency.conf 3840899018
verify config/overlays/beta-cohort.conf 2205352827
verify config/overlays/eu-privacy.conf 653910005
verify config/overlays/high-memory.conf 863486951
verify config/overlays/ledger-strict.conf 2435204197
verify config/overlays/legacy-clients.conf 924276917
verify config/overlays/low-memory.conf 3483741944
verify config/overlays/maintenance.conf 2721742538
verify config/overlays/peak-season.conf 273690016
verify config/overlays/search-experiment.conf 3437795537
verify config/sinks/apac-collector.conf 2684312510
verify config/sinks/archive.conf 4070175175
verify config/sinks/debug.conf 1188560893
verify config/sinks/eu-collector.conf 2126150707
verify config/sinks/legacy.conf 1972625407
verify config/sinks/primary.conf 1762662245
verify config/sinks/secondary.conf 2654013685
verify config/sinks/us-collector.conf 641031658
verify deploy/canary/apac-south/env.list 2552771969
verify deploy/canary/apac-south/target.conf 1095744137
verify deploy/canary/eu-central/env.list 3410055667
verify deploy/canary/eu-central/target.conf 3410540269
verify deploy/canary/eu-west/env.list 4095313005
verify deploy/canary/eu-west/target.conf 449985263
verify deploy/canary/us-east/env.list 270870497
verify deploy/canary/us-east/target.conf 2559848888
verify deploy/dev/apac-south/env.list 544450318
verify deploy/dev/apac-south/target.conf 1920940717
verify deploy/dev/eu-central/env.list 3480692923
verify deploy/dev/eu-central/target.conf 3904818416
verify deploy/dev/eu-west/env.list 2365122210
verify deploy/dev/eu-west/target.conf 4124718943
verify deploy/dev/us-east/env.list 4127118802
verify deploy/dev/us-east/target.conf 1530935615
verify deploy/prod/apac-south/env.list 1062853407
verify deploy/prod/apac-south/target.conf 802086761
verify deploy/prod/eu-central/env.list 2402157646
verify deploy/prod/eu-central/target.conf 1506388549
verify deploy/prod/eu-west/env.list 2395538852
verify deploy/prod/eu-west/target.conf 405226035
verify deploy/prod/us-east/env.list 2973452193
verify deploy/prod/us-east/target.conf 3793626213
verify deploy/staging/apac-south/env.list 4105452403
verify deploy/staging/apac-south/target.conf 2322695460
verify deploy/staging/eu-central/env.list 3915887328
verify deploy/staging/eu-central/target.conf 3687107421
verify deploy/staging/eu-west/env.list 50258485
verify deploy/staging/eu-west/target.conf 2388298770
verify deploy/staging/us-east/env.list 87810671
verify deploy/staging/us-east/target.conf 2108462435
verify docs/keys-reference.md 3165885172
verify docs/rollout-notes.md 1519288807
verify docs/rollouts/canary/apac-south.md 919549581
verify docs/rollouts/canary/eu-central.md 3531134128
verify docs/rollouts/canary/eu-west.md 460057819
verify docs/rollouts/canary/us-east.md 3038339810
verify docs/rollouts/dev/apac-south.md 2550531162
verify docs/rollouts/dev/eu-central.md 3922236793
verify docs/rollouts/dev/eu-west.md 1968378641
verify docs/rollouts/dev/us-east.md 1411674126
verify docs/rollouts/prod/apac-south.md 2572443741
verify docs/rollouts/prod/eu-central.md 3747538646
verify docs/rollouts/prod/eu-west.md 65540552
verify docs/rollouts/prod/us-east.md 2570946256
verify docs/rollouts/staging/apac-south.md 2942610884
verify docs/rollouts/staging/eu-central.md 280091134
verify docs/rollouts/staging/eu-west.md 511154290
verify docs/rollouts/staging/us-east.md 3127231455
verify history/changes-2026-03.md 2851209457
verify history/changes-2026-04.md 556846058
verify history/changes-2026-05.md 1720895240
verify history/changes-2026-06.md 3717714604
verify history/changes-2026-07.md 4069371149
verify history/changes-2026-08.md 1902932484
verify inventory/hosts.tsv 2109324740
verify policy/canary/locked.conf 1650638681
verify policy/dev/locked.conf 574602138
verify policy/prod/locked.conf 181832106
verify policy/staging/locked.conf 1908024893
verify profiles/admin.conf 1185720604
verify profiles/api-internal.conf 732468888
verify profiles/api-public.conf 2080207633
verify profiles/api.conf 2763882454
verify profiles/base.conf 732688943
verify profiles/billing-nightly.conf 90422967
verify profiles/billing.conf 3524393928
verify profiles/catalog-static.conf 3254005221
verify profiles/catalog.conf 1965999321
verify profiles/edge-lite.conf 349906216
verify profiles/edge.conf 583701169
verify profiles/export-bulk.conf 1435618492
verify profiles/export.conf 775402464
verify profiles/gateway-apac.conf 3363587260
verify profiles/gateway-eu.conf 3912081231
verify profiles/gateway-us.conf 905764812
verify profiles/gateway.conf 3590924622
verify profiles/ledger-audit.conf 3090145100
verify profiles/ledger.conf 3145801924
verify profiles/metrics-sampled.conf 2422959504
verify profiles/metrics.conf 1703914730
verify profiles/search-warm.conf 2770547932
verify profiles/search.conf 2567449751
verify profiles/service.conf 3742576284
verify profiles/web-cold.conf 3232743198
verify profiles/web-hot.conf 810850873
verify profiles/web.conf 3803279670
verify profiles/worker-batch.conf 40099225
verify profiles/worker-stream.conf 3122408682
verify profiles/worker.conf 3815094179
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\062\060'
expect 2 '\160\157\154\151\143\171\057\163\164\141\147\151\156\147\057\154\157\143\153\145\144\056\143\157\156\146'
echo "report ok"
