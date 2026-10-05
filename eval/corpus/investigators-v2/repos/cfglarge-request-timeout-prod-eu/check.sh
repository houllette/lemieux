#!/bin/sh
# Grader for cfglarge-request-timeout-prod-eu: every fixture file must be unchanged and the
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
verify config/archive/api-public-4.conf 3931706275
verify config/archive/gateway-0.conf 21989859
verify config/archive/gateway-apac-5.conf 3457709829
verify config/archive/gateway-us-1.conf 1119039604
verify config/archive/metrics-2.conf 383164490
verify config/archive/service-3.conf 960572908
verify config/includes/apac-tuning.conf 1845487712
verify config/includes/audit-tuning.conf 3601784643
verify config/includes/batch-tuning.conf 4114666883
verify config/includes/cache-defaults.conf 2304932166
verify config/includes/cold-path.conf 2084270412
verify config/includes/compat-2025.conf 100675360
verify config/includes/eu-tuning.conf 1702060795
verify config/includes/feature-defaults.conf 4036722271
verify config/includes/hot-path.conf 786659926
verify config/includes/limits-defaults.conf 3804897455
verify config/includes/logging-defaults.conf 397988906
verify config/includes/pools.conf 1390725239
verify config/includes/queue-defaults.conf 512991950
verify config/includes/timeouts.conf 2288724717
verify config/includes/tls-defaults.conf 3550122936
verify config/includes/us-tuning.conf 2911902310
verify config/overlays/apac-latency.conf 220493852
verify config/overlays/beta-cohort.conf 1302138305
verify config/overlays/eu-privacy.conf 626791582
verify config/overlays/high-memory.conf 1275486012
verify config/overlays/ledger-strict.conf 2501538676
verify config/overlays/legacy-clients.conf 670916725
verify config/overlays/low-memory.conf 1056292291
verify config/overlays/maintenance.conf 4260895045
verify config/overlays/peak-season.conf 2061690888
verify config/overlays/search-experiment.conf 1505568059
verify config/sinks/apac-collector.conf 2100626271
verify config/sinks/archive.conf 4265091532
verify config/sinks/debug.conf 685214881
verify config/sinks/eu-collector.conf 2564764912
verify config/sinks/legacy.conf 3129244513
verify config/sinks/primary.conf 2953849322
verify config/sinks/secondary.conf 1475604977
verify config/sinks/us-collector.conf 3386728978
verify deploy/canary/apac-south/env.list 543646589
verify deploy/canary/apac-south/target.conf 3781836900
verify deploy/canary/eu-central/env.list 3092750394
verify deploy/canary/eu-central/target.conf 711749722
verify deploy/canary/eu-west/env.list 2127036957
verify deploy/canary/eu-west/target.conf 1018116875
verify deploy/canary/us-east/env.list 781011741
verify deploy/canary/us-east/target.conf 841806862
verify deploy/dev/apac-south/env.list 1969437954
verify deploy/dev/apac-south/target.conf 896977142
verify deploy/dev/eu-central/env.list 1065530234
verify deploy/dev/eu-central/target.conf 397055185
verify deploy/dev/eu-west/env.list 1376433387
verify deploy/dev/eu-west/target.conf 3497211787
verify deploy/dev/us-east/env.list 618667175
verify deploy/dev/us-east/target.conf 3649523204
verify deploy/prod/apac-south/env.list 483469914
verify deploy/prod/apac-south/target.conf 1040844258
verify deploy/prod/eu-central/env.list 3271549157
verify deploy/prod/eu-central/target.conf 493646766
verify deploy/prod/eu-west/env.list 3830736294
verify deploy/prod/eu-west/target.conf 2654608432
verify deploy/prod/us-east/env.list 1216064946
verify deploy/prod/us-east/target.conf 2737035956
verify deploy/staging/apac-south/env.list 3235572268
verify deploy/staging/apac-south/target.conf 3868266063
verify deploy/staging/eu-central/env.list 2726568742
verify deploy/staging/eu-central/target.conf 805771461
verify deploy/staging/eu-west/env.list 4289657626
verify deploy/staging/eu-west/target.conf 114860764
verify deploy/staging/us-east/env.list 3786634629
verify deploy/staging/us-east/target.conf 1617198725
verify docs/keys-reference.md 3548039655
verify docs/rollout-notes.md 3834200315
verify docs/rollouts/canary/apac-south.md 1057965393
verify docs/rollouts/canary/eu-central.md 1371564391
verify docs/rollouts/canary/eu-west.md 915145276
verify docs/rollouts/canary/us-east.md 2183239274
verify docs/rollouts/dev/apac-south.md 1489007812
verify docs/rollouts/dev/eu-central.md 307861136
verify docs/rollouts/dev/eu-west.md 524918858
verify docs/rollouts/dev/us-east.md 828383059
verify docs/rollouts/prod/apac-south.md 2071314433
verify docs/rollouts/prod/eu-central.md 829026374
verify docs/rollouts/prod/eu-west.md 2005627349
verify docs/rollouts/prod/us-east.md 518842414
verify docs/rollouts/staging/apac-south.md 2804282747
verify docs/rollouts/staging/eu-central.md 3615926970
verify docs/rollouts/staging/eu-west.md 1427287479
verify docs/rollouts/staging/us-east.md 347947180
verify history/changes-2026-03.md 4118506263
verify history/changes-2026-04.md 2650051085
verify history/changes-2026-05.md 3516329344
verify history/changes-2026-06.md 3734704664
verify history/changes-2026-07.md 1888677660
verify history/changes-2026-08.md 1052192285
verify inventory/hosts.tsv 3083326162
verify policy/canary/locked.conf 3338101863
verify policy/dev/locked.conf 62619982
verify policy/prod/locked.conf 622973899
verify policy/staging/locked.conf 3537311199
verify profiles/admin.conf 1591757066
verify profiles/api-internal.conf 19430323
verify profiles/api-public.conf 3263886783
verify profiles/api.conf 2733043425
verify profiles/base.conf 2997278016
verify profiles/billing-nightly.conf 2363341314
verify profiles/billing.conf 3654104571
verify profiles/catalog-static.conf 2402725432
verify profiles/catalog.conf 4255120130
verify profiles/edge-lite.conf 1781737370
verify profiles/edge.conf 3239689195
verify profiles/export-bulk.conf 3365527444
verify profiles/export.conf 404339359
verify profiles/gateway-apac.conf 3131090625
verify profiles/gateway-eu.conf 2367418165
verify profiles/gateway-eu.conf.disabled 2906364925
verify profiles/gateway-us.conf 1103594647
verify profiles/gateway.conf 4051672740
verify profiles/ledger-audit.conf 2866560997
verify profiles/ledger.conf 3262411827
verify profiles/metrics-sampled.conf 4212619050
verify profiles/metrics.conf 4273193487
verify profiles/search-warm.conf 210766778
verify profiles/search.conf 3301172262
verify profiles/service.conf 779926592
verify profiles/web-cold.conf 1459493886
verify profiles/web-hot.conf 4052814614
verify profiles/web.conf 3265499636
verify profiles/worker-batch.conf 1204955315
verify profiles/worker-stream.conf 2912658024
verify profiles/worker.conf 4268901578
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\064\065\060\060'
expect 2 '\145\165\055\164\165\156\151\156\147'
echo "report ok"
