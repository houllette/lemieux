#!/bin/sh
# Grader for cfglarge-log-sink-hostname: every fixture file must be unchanged and the
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
verify config/archive/admin-4.conf 3402541651
verify config/archive/api-public-1.conf 4087309920
verify config/archive/base-2.conf 2357823397
verify config/archive/gateway-eu-0.conf 4137514488
verify config/archive/gateway-eu-3.conf 489928797
verify config/archive/ledger-5.conf 3927361852
verify config/includes/apac-tuning.conf 656723964
verify config/includes/audit-tuning.conf 3683906425
verify config/includes/batch-tuning.conf 3559499434
verify config/includes/cache-defaults.conf 3043864336
verify config/includes/cold-path.conf 1791494928
verify config/includes/compat-2025.conf 3264539161
verify config/includes/eu-tuning.conf 2667685201
verify config/includes/feature-defaults.conf 1137095714
verify config/includes/hot-path.conf 2816930925
verify config/includes/limits-defaults.conf 3821398110
verify config/includes/logging-defaults.conf 712333797
verify config/includes/pools.conf 1906685781
verify config/includes/queue-defaults.conf 4293139050
verify config/includes/timeouts.conf 494565625
verify config/includes/tls-defaults.conf 1317800790
verify config/includes/us-tuning.conf 775576497
verify config/overlays/apac-latency.conf 3204239390
verify config/overlays/beta-cohort.conf 2202940331
verify config/overlays/eu-privacy.conf 1565066331
verify config/overlays/high-memory.conf 4176253235
verify config/overlays/ledger-strict.conf 285393567
verify config/overlays/legacy-clients.conf 1082148464
verify config/overlays/low-memory.conf 1346899001
verify config/overlays/maintenance.conf 2724761620
verify config/overlays/peak-season.conf 3666931853
verify config/overlays/search-experiment.conf 2767227068
verify config/sinks/apac-collector.conf 894224852
verify config/sinks/archive.conf 2962077883
verify config/sinks/debug.conf 3691209662
verify config/sinks/eu-collector.conf 2162725808
verify config/sinks/legacy.conf 714630911
verify config/sinks/primary.conf 3605104346
verify config/sinks/secondary.conf 296084233
verify config/sinks/us-collector.conf 1851894055
verify deploy/canary/apac-south/env.list 2575957993
verify deploy/canary/apac-south/target.conf 3977908521
verify deploy/canary/eu-central/env.list 2606484116
verify deploy/canary/eu-central/target.conf 1501556708
verify deploy/canary/eu-west/env.list 3884384170
verify deploy/canary/eu-west/target.conf 3620047445
verify deploy/canary/us-east/env.list 3648707632
verify deploy/canary/us-east/target.conf 3946193406
verify deploy/dev/apac-south/env.list 1597535138
verify deploy/dev/apac-south/target.conf 4238649818
verify deploy/dev/eu-central/env.list 1560929473
verify deploy/dev/eu-central/target.conf 2587721170
verify deploy/dev/eu-west/env.list 4275234541
verify deploy/dev/eu-west/target.conf 4116381413
verify deploy/dev/us-east/env.list 3929396281
verify deploy/dev/us-east/target.conf 3322221079
verify deploy/prod/apac-south/env.list 3766300154
verify deploy/prod/apac-south/target.conf 1575408749
verify deploy/prod/eu-central/env.list 3522664219
verify deploy/prod/eu-central/target.conf 3740473678
verify deploy/prod/eu-west/env.list 1650671246
verify deploy/prod/eu-west/target.conf 3211895300
verify deploy/prod/us-east/env.list 1721797388
verify deploy/prod/us-east/target.conf 1773051123
verify deploy/staging/apac-south/env.list 2379758680
verify deploy/staging/apac-south/target.conf 3610002884
verify deploy/staging/eu-central/env.list 1007503983
verify deploy/staging/eu-central/target.conf 3407820504
verify deploy/staging/eu-west/env.list 497999334
verify deploy/staging/eu-west/target.conf 4293997457
verify deploy/staging/us-east/env.list 670309940
verify deploy/staging/us-east/target.conf 2517188111
verify docs/keys-reference.md 1720769458
verify docs/rollout-notes.md 2447357180
verify docs/rollouts/canary/apac-south.md 2247059611
verify docs/rollouts/canary/eu-central.md 3662762052
verify docs/rollouts/canary/eu-west.md 2072761995
verify docs/rollouts/canary/us-east.md 3636765655
verify docs/rollouts/dev/apac-south.md 3454770264
verify docs/rollouts/dev/eu-central.md 2502682488
verify docs/rollouts/dev/eu-west.md 2219434497
verify docs/rollouts/dev/us-east.md 1353999573
verify docs/rollouts/prod/apac-south.md 714897109
verify docs/rollouts/prod/eu-central.md 4002120245
verify docs/rollouts/prod/eu-west.md 3687422041
verify docs/rollouts/prod/us-east.md 3973591707
verify docs/rollouts/staging/apac-south.md 1594578878
verify docs/rollouts/staging/eu-central.md 1173600212
verify docs/rollouts/staging/eu-west.md 3680063389
verify docs/rollouts/staging/us-east.md 2224731972
verify history/changes-2026-03.md 2731874225
verify history/changes-2026-04.md 4230189595
verify history/changes-2026-05.md 2386869273
verify history/changes-2026-06.md 290172200
verify history/changes-2026-07.md 168396826
verify history/changes-2026-08.md 688093544
verify inventory/hosts.tsv 1302683397
verify policy/canary/locked.conf 1956211560
verify policy/dev/locked.conf 1913343100
verify policy/prod/locked.conf 2807656144
verify policy/staging/locked.conf 3188537471
verify profiles/admin.conf 1243556513
verify profiles/api-internal.conf 4079908050
verify profiles/api-public.conf 1912610070
verify profiles/api.conf 497756423
verify profiles/base.conf 938502271
verify profiles/billing-nightly.conf 375032074
verify profiles/billing.conf 3267918081
verify profiles/catalog-static.conf 1307131622
verify profiles/catalog.conf 1961248793
verify profiles/edge-lite.conf 3545729767
verify profiles/edge.conf 3876342075
verify profiles/export-bulk.conf 3574374255
verify profiles/export.conf 1000780418
verify profiles/gateway-apac.conf 298203082
verify profiles/gateway-eu.conf 398407608
verify profiles/gateway-us.conf 1386545443
verify profiles/gateway.conf 4094907481
verify profiles/ledger-audit.conf 3312752766
verify profiles/ledger.conf 3826913790
verify profiles/metrics-sampled.conf 2910050364
verify profiles/metrics.conf 2689760387
verify profiles/search-warm.conf 2623444883
verify profiles/search-warm.conf.disabled 2748027161
verify profiles/search.conf 1631613940
verify profiles/service.conf 3783120284
verify profiles/web-cold.conf 2888806815
verify profiles/web-hot.conf 4113172711
verify profiles/web.conf 2932698510
verify profiles/worker-batch.conf 1448681486
verify profiles/worker-stream.conf 492771429
verify profiles/worker.conf 3433283564
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\142\141\163\141\154\164\055\143\157\154\154\145\143\164\157\162\055\061\066\056\145\170\141\155\160\154\145\056\164\145\163\164'
echo "report ok"
