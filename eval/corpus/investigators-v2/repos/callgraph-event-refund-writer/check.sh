#!/bin/sh
# Grader for callgraph-event-refund-writer: every fixture file must be unchanged and the
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
verify README.md 1456546762
verify app/__init__.py 944556697
verify app/cli/__init__.py 2519210452
verify app/cli/main.py 208317528
verify app/cli/output.py 1270569712
verify app/cli/registry.py 640328369
verify app/commands/__init__.py 3940485025
verify app/commands/export.py 2259102322
verify app/commands/import_.py 4219978309
verify app/commands/prune.py 3714874664
verify app/commands/reconcile.py 2239871316
verify app/commands/rollup.py 1329084934
verify app/commands/status.py 4242042635
verify app/core/__init__.py 1119839607
verify app/core/clock.py 1018177181
verify app/core/config.py 1793340420
verify app/core/container.py 3024496729
verify app/core/errors.py 3211180115
verify app/core/logging_setup.py 966330903
verify app/core/retry.py 2928812716
verify app/events/__init__.py 2278297817
verify app/events/bus.py 1576593604
verify app/events/replay.py 2835589104
verify app/events/subscriptions.py 374681531
verify app/generated/__init__.py 4294967295
verify app/generated/constants.py 3040279167
verify app/handlers/__init__.py 2550517144
verify app/handlers/cancellations.py 530337471
verify app/handlers/payments.py 1602177101
verify app/handlers/refunds.py 1960608785
verify app/handlers/shipments.py 1203858060
verify app/hashing/__init__.py 2843720077
verify app/hashing/crc_fold.py 1308221376
verify app/hashing/fold64.py 627625977
verify app/hashing/registry.py 3242656609
verify app/hashing/sha_like.py 255176478
verify app/http/__init__.py 2248361807
verify app/http/controllers.py 3212137747
verify app/http/middleware.py 1200673179
verify app/http/responses.py 316188422
verify app/http/routes.py 4147143929
verify app/legacy/__init__.py 133767244
verify app/legacy/audit.py 330980612
verify app/legacy/handlers.py 3159232883
verify app/legacy/hashing.py 2526994707
verify app/legacy/notify.py 2713534138
verify app/legacy/renderers.py 2747843229
verify app/models/__init__.py 1416109836
verify app/models/customer.py 2111417956
verify app/models/invoice.py 1864017749
verify app/models/ledger_entry.py 485281560
verify app/models/order.py 469223611
verify app/models/quota.py 10715815
verify app/models/snapshot.py 106082495
verify app/notify/__init__.py 3019589984
verify app/notify/backoff.py 2889520854
verify app/notify/channels/__init__.py 3835347059
verify app/notify/channels/chat.py 3807455920
verify app/notify/channels/mail.py 309638142
verify app/notify/channels/pager.py 1456422671
verify app/notify/channels/pager_v2.py 2102849946
verify app/notify/channels/webhook.py 2326000328
verify app/notify/router.py 3190839436
verify app/notify/templates.py 4147379970
verify app/render/__init__.py 4145259953
verify app/render/engine.py 1538491599
verify app/render/filters.py 2654535464
verify app/render/pdf_shim.py 1763246698
verify app/render/registry.py 956868386
verify app/scheduler/__init__.py 3361350856
verify app/scheduler/cron.py 399900633
verify app/scheduler/jobs.py 1545263972
verify app/scheduler/leases.py 1208150176
verify app/services/audit/__init__.py 1148846154
verify app/services/audit/filters.py 2761860685
verify app/services/audit/redaction.py 3424251378
verify app/services/audit/sink_v1.py 2537667820
verify app/services/audit/sink_v2.py 2005359940
verify app/services/ledger/__init__.py 2598886985
verify app/services/ledger/balances.py 1658199341
verify app/services/ledger/postings.py 3980816448
verify app/services/ledger/postings_legacy.py 2105677711
verify app/services/ledger/reconcile.py 867969432
verify app/services/quota/__init__.py 1015210046
verify app/services/quota/meter.py 595002817
verify app/services/quota/policy.py 2678132923
verify app/services/quota/reset.py 249174999
verify app/signals/__init__.py 3825551858
verify app/signals/dispatch.py 2356878521
verify app/signals/quota_signals.py 3836007555
verify app/signals/registry.py 3585118245
verify app/storage/__init__.py 2986927796
verify app/storage/blobs.py 2624654701
verify app/storage/index.py 2453253363
verify app/storage/journal.py 3769070518
verify app/storage/ledger_writer.py 2007328419
verify app/storage/legacy_journal.py 1081559143
verify app/storage/migrations.py 1740710876
verify app/tasks/__init__.py 2171532614
verify app/tasks/cleanup.py 636494681
verify app/tasks/hourly.py 3251893736
verify app/tasks/nightly.py 3460695630
verify app/tasks/reconcile.py 2894096683
verify config/bindings.conf 895564733
verify config/subscriptions.tsv 87100992
verify docs/architecture.md 2846644142
verify docs/modules/cli.md-10 453990021
verify docs/modules/core.md-1 1003769590
verify docs/modules/core.md-9 1244918152
verify docs/modules/hashing.md-6 452914878
verify docs/modules/hashing.md-8 2222970528
verify docs/modules/legacy.md-0 2278366771
verify docs/modules/legacy.md-11 675875335
verify docs/modules/legacy.md-4 1979064882
verify docs/modules/legacy.md-5 2048303473
verify docs/modules/legacy.md-7 3160222018
verify docs/modules/render.md-2 1745119876
verify docs/modules/signals.md-3 1638983977
verify docs/runbooks/birch-4.md 2140339658
verify docs/runbooks/delta-5.md 3351599158
verify docs/runbooks/moss-2.md 4185808190
verify docs/runbooks/rowan-3.md 3180553759
verify docs/runbooks/russet-0.md 3645542644
verify docs/runbooks/slate-1.md 1051105824
verify tests/test_alder_6.py 1089744455
verify tests/test_anvil_17.py 2436493417
verify tests/test_badger_14.py 624765679
verify tests/test_blaze_0.py 545258627
verify tests/test_brine_11.py 2675598982
verify tests/test_cedar_3.py 571411059
verify tests/test_cobalt_7.py 694974705
verify tests/test_copper_9.py 2523483224
verify tests/test_coral_8.py 1226651009
verify tests/test_fathom_12.py 2168218881
verify tests/test_garnet_2.py 1188071607
verify tests/test_ingot_13.py 3873607723
verify tests/test_meadow_4.py 3637329287
verify tests/test_mica_18.py 4057040717
verify tests/test_orchard_19.py 1661399337
verify tests/test_pewter_15.py 1251966955
verify tests/test_sedge_16.py 851253197
verify tests/test_sorrel_5.py 656867341
verify tests/test_topaz_10.py 3971198355
verify tests/test_verdant_1.py 1224306777
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\160\157\163\164\137\141\144\152\165\163\164\155\145\156\164'
expect 2 '\141\160\160\057\163\164\157\162\141\147\145\057\154\145\144\147\145\162\137\167\162\151\164\145\162\056\160\171'
echo "report ok"
