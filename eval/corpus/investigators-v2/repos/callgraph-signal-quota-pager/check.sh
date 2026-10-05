#!/bin/sh
# Grader for callgraph-signal-quota-pager: every fixture file must be unchanged and the
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
verify README.md 788096832
verify app/__init__.py 944556697
verify app/cli/__init__.py 2519210452
verify app/cli/main.py 1161561470
verify app/cli/output.py 3593464825
verify app/cli/registry.py 851431340
verify app/commands/__init__.py 3940485025
verify app/commands/export.py 2259631185
verify app/commands/import_.py 3955120720
verify app/commands/prune.py 875815918
verify app/commands/reconcile.py 1862464639
verify app/commands/rollup.py 2322120364
verify app/commands/status.py 3221825037
verify app/core/__init__.py 1119839607
verify app/core/clock.py 3452782864
verify app/core/config.py 384081786
verify app/core/container.py 3024496729
verify app/core/errors.py 3512396823
verify app/core/logging_setup.py 428745308
verify app/core/retry.py 3977338700
verify app/events/__init__.py 2278297817
verify app/events/bus.py 1522262961
verify app/events/replay.py 1157077163
verify app/events/subscriptions.py 170060229
verify app/generated/__init__.py 4294967295
verify app/generated/constants.py 185250816
verify app/handlers/__init__.py 3719374476
verify app/handlers/cancellations.py 2853455038
verify app/handlers/payments.py 608885594
verify app/handlers/refunds.py 3113785212
verify app/handlers/shipments.py 103526120
verify app/hashing/__init__.py 2843720077
verify app/hashing/crc_fold.py 3421309071
verify app/hashing/fold64.py 901698062
verify app/hashing/registry.py 67125309
verify app/hashing/sha_like.py 245120764
verify app/http/__init__.py 2248361807
verify app/http/controllers.py 1721549603
verify app/http/middleware.py 508627848
verify app/http/responses.py 767872067
verify app/http/routes.py 3883458429
verify app/legacy/__init__.py 133767244
verify app/legacy/audit.py 1591307562
verify app/legacy/handlers.py 3081486789
verify app/legacy/hashing.py 2614989818
verify app/legacy/notify.py 3665053065
verify app/legacy/renderers.py 2870563486
verify app/models/__init__.py 1416109836
verify app/models/customer.py 4274898002
verify app/models/invoice.py 3802541629
verify app/models/ledger_entry.py 2874353455
verify app/models/order.py 22876254
verify app/models/quota.py 2668241443
verify app/models/snapshot.py 37600124
verify app/notify/__init__.py 3019589984
verify app/notify/backoff.py 2822462215
verify app/notify/channels/__init__.py 3835347059
verify app/notify/channels/chat.py 3184545272
verify app/notify/channels/mail.py 3162280478
verify app/notify/channels/pager.py 1749926546
verify app/notify/channels/pager_v2.py 2372500592
verify app/notify/channels/webhook.py 1813202136
verify app/notify/router.py 849667133
verify app/notify/templates.py 3447626202
verify app/render/__init__.py 4145259953
verify app/render/engine.py 616852745
verify app/render/filters.py 4118268044
verify app/render/pdf_shim.py 55524456
verify app/render/registry.py 3636040001
verify app/scheduler/__init__.py 3361350856
verify app/scheduler/cron.py 2504240328
verify app/scheduler/jobs.py 4250931911
verify app/scheduler/leases.py 757235579
verify app/services/audit/__init__.py 1148846154
verify app/services/audit/filters.py 2185673329
verify app/services/audit/redaction.py 1894986710
verify app/services/audit/sink_v1.py 3321233329
verify app/services/audit/sink_v2.py 1952124526
verify app/services/ledger/__init__.py 2598886985
verify app/services/ledger/balances.py 4062587795
verify app/services/ledger/postings.py 726244079
verify app/services/ledger/postings_legacy.py 3488037201
verify app/services/ledger/reconcile.py 2808214236
verify app/services/quota/__init__.py 1015210046
verify app/services/quota/meter.py 3586257786
verify app/services/quota/policy.py 1881055663
verify app/services/quota/reset.py 2952173719
verify app/signals/__init__.py 3825551858
verify app/signals/dispatch.py 3541477066
verify app/signals/quota_signals.py 1911889786
verify app/signals/registry.py 960088694
verify app/storage/__init__.py 2986927796
verify app/storage/blobs.py 1608514145
verify app/storage/index.py 322599480
verify app/storage/journal.py 3113589963
verify app/storage/ledger_writer.py 2242377798
verify app/storage/legacy_journal.py 1102400159
verify app/storage/migrations.py 2897492237
verify app/tasks/__init__.py 2171532614
verify app/tasks/cleanup.py 2328356629
verify app/tasks/hourly.py 810487398
verify app/tasks/nightly.py 1935271693
verify app/tasks/reconcile.py 3561168709
verify config/channels.conf 471456674
verify config/channels.conf.orig 191058153
verify config/signals.tsv 2424255368
verify docs/architecture.md 4012628808
verify docs/modules/audit.md-2 562901134
verify docs/modules/audit.md-3 2693410003
verify docs/modules/cli.md-4 4142391026
verify docs/modules/cli.md-6 2281187106
verify docs/modules/commands.md-7 2378548532
verify docs/modules/events.md-0 3537454930
verify docs/modules/handlers.md-11 2955040826
verify docs/modules/hashing.md-1 2632366685
verify docs/modules/http.md-8 1235433388
verify docs/modules/ledger.md-5 1014760317
verify docs/modules/legacy.md-9 3370488628
verify docs/modules/storage.md-10 4090424119
verify docs/runbooks/dapple-2.md 4111190658
verify docs/runbooks/granite-3.md 680499043
verify docs/runbooks/harbor-0.md 3101582584
verify docs/runbooks/lichen-4.md 3497625134
verify docs/runbooks/sterling-1.md 3315511123
verify docs/runbooks/thistle-5.md 2358687807
verify tests/test_alder_8.py 85356299
verify tests/test_atlas_7.py 3410322646
verify tests/test_beacon_13.py 1141129068
verify tests/test_canvas_10.py 781606398
verify tests/test_copper_14.py 2022187841
verify tests/test_gravel_19.py 941263415
verify tests/test_larch_3.py 607090340
verify tests/test_lichen_5.py 3000841176
verify tests/test_lumen_16.py 4015356930
verify tests/test_lumen_2.py 3987180054
verify tests/test_marrow_11.py 2285976029
verify tests/test_orchard_1.py 2633599297
verify tests/test_pebble_15.py 4010039394
verify tests/test_reed_4.py 1204680235
verify tests/test_spruce_0.py 824940553
verify tests/test_spruce_9.py 50890421
verify tests/test_sterling_17.py 871821380
verify tests/test_tallow_12.py 3089901878
verify tests/test_thistle_18.py 3936441561
verify tests/test_verdant_6.py 3211594755
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\144\145\154\151\166\145\162\137\160\141\147\145'
expect 2 '\141\160\160\057\156\157\164\151\146\171\057\143\150\141\156\156\145\154\163\057\160\141\147\145\162\137\166\062\056\160\171'
echo "report ok"
