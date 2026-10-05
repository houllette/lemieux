#!/bin/sh
# Grader for cfglarge-overlay-order-variant: every fixture file must be unchanged and the
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
verify config/archive/admin-0.conf 3026841557
verify config/archive/api-public-prod.conf 3083256757
verify config/archive/catalog-static-4.conf 25854847
verify config/archive/edge-2.conf 3145922996
verify config/archive/export-1.conf 4187198911
verify config/archive/ledger-audit-5.conf 1776986272
verify config/archive/metrics-3.conf 3593532290
verify config/includes/apac-tuning.conf 573710072
verify config/includes/audit-tuning.conf 1482615555
verify config/includes/batch-tuning.conf 2274517873
verify config/includes/cache-defaults.conf 1331962484
verify config/includes/cold-path.conf 2154530205
verify config/includes/compat-2025.conf 2620438313
verify config/includes/eu-tuning.conf 2288745915
verify config/includes/feature-defaults.conf 3027828584
verify config/includes/hot-path.conf 3131868183
verify config/includes/limits-defaults.conf 163629558
verify config/includes/logging-defaults.conf 3783931492
verify config/includes/pools.conf 507809070
verify config/includes/queue-defaults.conf 1759588251
verify config/includes/timeouts.conf 244584275
verify config/includes/tls-defaults.conf 1301251609
verify config/includes/us-tuning.conf 3439627212
verify config/overlays/apac-latency.conf 3287922043
verify config/overlays/beta-cohort.conf 2851058796
verify config/overlays/eu-privacy.conf 2236570717
verify config/overlays/high-memory.conf 1191621399
verify config/overlays/ledger-strict.conf 3214416548
verify config/overlays/legacy-clients.conf 712933238
verify config/overlays/low-memory.conf 2223842468
verify config/overlays/maintenance.conf 3491394877
verify config/overlays/peak-season.conf 2857646973
verify config/overlays/search-experiment.conf 174573172
verify config/sinks/apac-collector.conf 2061393414
verify config/sinks/archive.conf 2683252775
verify config/sinks/debug.conf 1980027360
verify config/sinks/eu-collector.conf 3758034524
verify config/sinks/legacy.conf 1985283132
verify config/sinks/primary.conf 1431228934
verify config/sinks/secondary.conf 1769389249
verify config/sinks/us-collector.conf 1121726002
verify deploy/canary/apac-south/env.list 2838568794
verify deploy/canary/apac-south/target.conf 1902115609
verify deploy/canary/eu-central/env.list 4270957124
verify deploy/canary/eu-central/target.conf 3309308861
verify deploy/canary/eu-west/env.list 3350389461
verify deploy/canary/eu-west/target.conf 1240977911
verify deploy/canary/us-east/env.list 745457059
verify deploy/canary/us-east/target.conf 1277135365
verify deploy/dev/apac-south/env.list 1473887052
verify deploy/dev/apac-south/target.conf 1930215266
verify deploy/dev/eu-central/env.list 3569463662
verify deploy/dev/eu-central/target.conf 1955632131
verify deploy/dev/eu-west/env.list 2148819619
verify deploy/dev/eu-west/target.conf 3007119554
verify deploy/dev/us-east/env.list 2486389179
verify deploy/dev/us-east/target.conf 4252160830
verify deploy/prod/apac-south/env.list 2214216905
verify deploy/prod/apac-south/target.conf 3516008545
verify deploy/prod/eu-central/env.list 2143042804
verify deploy/prod/eu-central/target.conf 1993042133
verify deploy/prod/eu-west/env.list 972235657
verify deploy/prod/eu-west/target.conf 4269400567
verify deploy/prod/us-east/env.list 3711853715
verify deploy/prod/us-east/target.conf 2686117134
verify deploy/staging/apac-south/env.list 3651614735
verify deploy/staging/apac-south/target.conf 1460409653
verify deploy/staging/eu-central/env.list 2612732132
verify deploy/staging/eu-central/target.conf 3900647526
verify deploy/staging/eu-west/env.list 3252790443
verify deploy/staging/eu-west/target.conf 2856316513
verify deploy/staging/us-east/env.list 1698054204
verify deploy/staging/us-east/target.conf 1352588319
verify docs/keys-reference.md 570643317
verify docs/rollout-notes.md 3858000943
verify docs/rollouts/canary/apac-south.md 500587849
verify docs/rollouts/canary/eu-central.md 4046505317
verify docs/rollouts/canary/eu-west.md 232732324
verify docs/rollouts/canary/us-east.md 4084954792
verify docs/rollouts/dev/apac-south.md 2749077336
verify docs/rollouts/dev/eu-central.md 889713202
verify docs/rollouts/dev/eu-west.md 592018318
verify docs/rollouts/dev/us-east.md 1216478300
verify docs/rollouts/prod/apac-south.md 3576394282
verify docs/rollouts/prod/eu-central.md 3215969086
verify docs/rollouts/prod/eu-west.md 4290373096
verify docs/rollouts/prod/us-east.md 1997914921
verify docs/rollouts/staging/apac-south.md 157331026
verify docs/rollouts/staging/eu-central.md 699587154
verify docs/rollouts/staging/eu-west.md 795001381
verify docs/rollouts/staging/us-east.md 2870527788
verify history/changes-2026-03.md 1766820744
verify history/changes-2026-04.md 1108186297
verify history/changes-2026-05.md 3991427246
verify history/changes-2026-06.md 2230915694
verify history/changes-2026-07.md 1249002696
verify history/changes-2026-08.md 2668945392
verify inventory/hosts.tsv 513636470
verify policy/canary/locked.conf 3099234943
verify policy/dev/locked.conf 3876612506
verify policy/prod/locked.conf 4002654253
verify policy/staging/locked.conf 3324259345
verify profiles/admin.conf 3499989457
verify profiles/api-internal.conf 2381880562
verify profiles/api-public.conf 557004283
verify profiles/api.conf 1041585859
verify profiles/base.conf 1694676006
verify profiles/billing-nightly.conf 1447692948
verify profiles/billing.conf 3300019508
verify profiles/catalog-static.conf 2357372500
verify profiles/catalog.conf 4276307382
verify profiles/edge-lite.conf 4007855415
verify profiles/edge.conf 139135061
verify profiles/export-bulk.conf 2223750466
verify profiles/export.conf 699638042
verify profiles/gateway-apac.conf 2891709926
verify profiles/gateway-eu.conf 445005744
verify profiles/gateway-us.conf 2967341836
verify profiles/gateway.conf 2408407759
verify profiles/ledger-audit.conf 4052485957
verify profiles/ledger.conf 2066361214
verify profiles/metrics-sampled.conf 2320398735
verify profiles/metrics.conf 2742589896
verify profiles/search-warm.conf 2528459512
verify profiles/search.conf 4050309286
verify profiles/service.conf 3025520580
verify profiles/web-cold.conf 2399585159
verify profiles/web-hot.conf 1899872994
verify profiles/web.conf 45493548
verify profiles/worker-batch.conf 3836357683
verify profiles/worker-stream.conf 3536611863
verify profiles/worker.conf 1251791472
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\143\157\155\160\141\143\164'
expect 2 '\141\160\141\143\055\154\141\164\145\156\143\171'
echo "report ok"
