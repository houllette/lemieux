#!/bin/sh
# Grader for callgraph-cli-export-audit-writer: every fixture file must be unchanged and the
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
verify README.md 1031102916
verify app/__init__.py 944556697
verify app/cli/__init__.py 2519210452
verify app/cli/main.py 3190232587
verify app/cli/output.py 3396958769
verify app/cli/registry.py 3613617704
verify app/commands/__init__.py 3940485025
verify app/commands/export.py 1054024493
verify app/commands/import_.py 808710621
verify app/commands/prune.py 3149961859
verify app/commands/reconcile.py 858936658
verify app/commands/rollup.py 2878337055
verify app/commands/status.py 3856384600
verify app/core/__init__.py 1119839607
verify app/core/clock.py 2884175320
verify app/core/config.py 3373675073
verify app/core/container.py 3024496729
verify app/core/errors.py 1965891798
verify app/core/logging_setup.py 1998681699
verify app/core/retry.py 453857162
verify app/events/__init__.py 2278297817
verify app/events/bus.py 1592892802
verify app/events/replay.py 489357930
verify app/events/subscriptions.py 271903281
verify app/generated/__init__.py 4294967295
verify app/generated/constants.py 1318931361
verify app/handlers/__init__.py 3719374476
verify app/handlers/cancellations.py 4043463151
verify app/handlers/payments.py 2209885641
verify app/handlers/refunds.py 4189389944
verify app/handlers/shipments.py 2816375167
verify app/hashing/__init__.py 2843720077
verify app/hashing/crc_fold.py 105086255
verify app/hashing/fold64.py 2722003590
verify app/hashing/registry.py 1039624059
verify app/hashing/sha_like.py 1570885972
verify app/http/__init__.py 2248361807
verify app/http/controllers.py 2451912697
verify app/http/middleware.py 3378701443
verify app/http/responses.py 4247943563
verify app/http/routes.py 929578298
verify app/legacy/__init__.py 133767244
verify app/legacy/audit.py 3613048945
verify app/legacy/handlers.py 1958551801
verify app/legacy/hashing.py 156796910
verify app/legacy/notify.py 4180314836
verify app/legacy/renderers.py 3014169261
verify app/models/__init__.py 1416109836
verify app/models/customer.py 827773094
verify app/models/invoice.py 566637011
verify app/models/ledger_entry.py 227481201
verify app/models/order.py 1138044452
verify app/models/quota.py 3013461645
verify app/models/snapshot.py 2083763924
verify app/notify/__init__.py 3019589984
verify app/notify/backoff.py 1514313154
verify app/notify/channels/__init__.py 3835347059
verify app/notify/channels/chat.py 4012464726
verify app/notify/channels/mail.py 1976314677
verify app/notify/channels/pager.py 1901389349
verify app/notify/channels/pager_v2.py 53788604
verify app/notify/channels/webhook.py 4141351766
verify app/notify/router.py 404428058
verify app/notify/templates.py 822466274
verify app/render/__init__.py 4145259953
verify app/render/engine.py 1432302745
verify app/render/filters.py 374586394
verify app/render/pdf_shim.py 606796030
verify app/render/registry.py 1836845277
verify app/scheduler/__init__.py 3361350856
verify app/scheduler/cron.py 2334079981
verify app/scheduler/jobs.py 3779926181
verify app/scheduler/leases.py 2590568339
verify app/services/audit/__init__.py 1148846154
verify app/services/audit/filters.py 610657961
verify app/services/audit/redaction.py 3403699709
verify app/services/audit/sink_v1.py 2630452862
verify app/services/audit/sink_v2.py 1044787330
verify app/services/ledger/__init__.py 2598886985
verify app/services/ledger/balances.py 1958447597
verify app/services/ledger/postings.py 3775080794
verify app/services/ledger/postings_legacy.py 2714084584
verify app/services/ledger/reconcile.py 3938013225
verify app/services/quota/__init__.py 1015210046
verify app/services/quota/meter.py 3721725061
verify app/services/quota/policy.py 2442897668
verify app/services/quota/reset.py 1285655490
verify app/signals/__init__.py 3825551858
verify app/signals/dispatch.py 782602332
verify app/signals/quota_signals.py 631603874
verify app/signals/registry.py 2871622476
verify app/storage/__init__.py 2986927796
verify app/storage/blobs.py 2203071015
verify app/storage/index.py 3135772234
verify app/storage/journal.py 4189206307
verify app/storage/ledger_writer.py 1895110151
verify app/storage/legacy_journal.py 1618072832
verify app/storage/migrations.py 983927872
verify app/tasks/__init__.py 2171532614
verify app/tasks/cleanup.py 2340649048
verify app/tasks/hourly.py 3625784717
verify app/tasks/nightly.py 1111926161
verify app/tasks/reconcile.py 897051656
verify config/bindings.conf 3520008387
verify config/bindings.local.conf.example 3713124992
verify config/commands.tsv 2462890297
verify docs/architecture.md 3614865628
verify docs/modules/cli.md-0 531074808
verify docs/modules/core.md-11 2093710239
verify docs/modules/core.md-3 548144391
verify docs/modules/http.md-1 2401598516
verify docs/modules/http.md-4 548811659
verify docs/modules/legacy.md-9 2168482260
verify docs/modules/models.md-8 2190038871
verify docs/modules/quota.md-10 432402838
verify docs/modules/quota.md-2 302330158
verify docs/modules/render.md-5 257227758
verify docs/modules/scheduler.md-7 3512652980
verify docs/modules/signals.md-6 1368690596
verify docs/runbooks/birch-2.md 1576309057
verify docs/runbooks/iris-5.md 4172818659
verify docs/runbooks/linden-3.md 1501074709
verify docs/runbooks/pine-0.md 3831211184
verify docs/runbooks/russet-1.md 2307074219
verify docs/runbooks/vale-4.md 29396009
verify tests/test_arbor_7.py 123318295
verify tests/test_basalt_17.py 79263373
verify tests/test_bison_6.py 2434871421
verify tests/test_blaze_4.py 1534636561
verify tests/test_cobalt_9.py 2770840786
verify tests/test_comet_3.py 2617373
verify tests/test_dapple_8.py 519189172
verify tests/test_fennel_5.py 4258955091
verify tests/test_fjord_10.py 1223239483
verify tests/test_flint_19.py 1333301383
verify tests/test_harbor_16.py 3396811393
verify tests/test_hollow_15.py 3403816897
verify tests/test_hollow_18.py 2552403868
verify tests/test_jasper_2.py 694195661
verify tests/test_lichen_0.py 2448124957
verify tests/test_meadow_11.py 736045686
verify tests/test_moss_13.py 3749370711
verify tests/test_osprey_12.py 4044345178
verify tests/test_tarn_1.py 2307811920
verify tests/test_timber_14.py 1660261044
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\141\160\160\145\156\144\137\162\145\143\157\162\144'
expect 2 '\141\160\160\057\163\164\157\162\141\147\145\057\152\157\165\162\156\141\154\056\160\171'
echo "report ok"
