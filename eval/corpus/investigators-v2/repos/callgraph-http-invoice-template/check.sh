#!/bin/sh
# Grader for callgraph-http-invoice-template: every fixture file must be unchanged and the
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
verify README.md 534498559
verify app/__init__.py 944556697
verify app/cli/__init__.py 2519210452
verify app/cli/main.py 3281360414
verify app/cli/output.py 4150645613
verify app/cli/registry.py 540439980
verify app/commands/__init__.py 3940485025
verify app/commands/export.py 1726674621
verify app/commands/import_.py 3526286748
verify app/commands/prune.py 14786550
verify app/commands/reconcile.py 3895794194
verify app/commands/rollup.py 3431404869
verify app/commands/status.py 3566206803
verify app/core/__init__.py 1119839607
verify app/core/clock.py 703999647
verify app/core/config.py 1755164729
verify app/core/container.py 3024496729
verify app/core/errors.py 3223353138
verify app/core/logging_setup.py 3217281521
verify app/core/retry.py 3172258140
verify app/events/__init__.py 2278297817
verify app/events/bus.py 741648099
verify app/events/replay.py 3660886593
verify app/events/subscriptions.py 326006010
verify app/generated/__init__.py 4294967295
verify app/generated/constants.py 619004677
verify app/handlers/__init__.py 3719374476
verify app/handlers/cancellations.py 328069429
verify app/handlers/payments.py 1626276737
verify app/handlers/refunds.py 2729029534
verify app/handlers/shipments.py 1495301523
verify app/hashing/__init__.py 2843720077
verify app/hashing/crc_fold.py 2550355411
verify app/hashing/fold64.py 1897281182
verify app/hashing/registry.py 3133446857
verify app/hashing/sha_like.py 1691556232
verify app/http/__init__.py 2248361807
verify app/http/controllers.py 2528479651
verify app/http/middleware.py 4226002504
verify app/http/responses.py 1034580080
verify app/http/routes.py 3057932995
verify app/legacy/__init__.py 133767244
verify app/legacy/audit.py 2399053586
verify app/legacy/handlers.py 3210013371
verify app/legacy/hashing.py 1104551044
verify app/legacy/notify.py 2485753116
verify app/legacy/renderers.py 653993476
verify app/models/__init__.py 1416109836
verify app/models/customer.py 4091773562
verify app/models/invoice.py 2511963795
verify app/models/ledger_entry.py 380520112
verify app/models/order.py 2876669267
verify app/models/quota.py 3689613810
verify app/models/snapshot.py 1172590531
verify app/notify/__init__.py 3019589984
verify app/notify/backoff.py 3675513420
verify app/notify/channels/__init__.py 3835347059
verify app/notify/channels/chat.py 452390174
verify app/notify/channels/mail.py 2803134732
verify app/notify/channels/pager.py 3251941334
verify app/notify/channels/pager_v2.py 3362501316
verify app/notify/channels/webhook.py 4254656739
verify app/notify/router.py 1415345678
verify app/notify/templates.py 187803123
verify app/render/__init__.py 4145259953
verify app/render/engine.py 2354439606
verify app/render/filters.py 2341129304
verify app/render/pdf_shim.py 3678561407
verify app/render/registry.py 2857897195
verify app/scheduler/__init__.py 3361350856
verify app/scheduler/cron.py 634210360
verify app/scheduler/jobs.py 176398088
verify app/scheduler/leases.py 68362680
verify app/services/audit/__init__.py 1148846154
verify app/services/audit/filters.py 3881148229
verify app/services/audit/redaction.py 715318130
verify app/services/audit/sink_v1.py 2201631701
verify app/services/audit/sink_v2.py 3461268237
verify app/services/ledger/__init__.py 2598886985
verify app/services/ledger/balances.py 1712291447
verify app/services/ledger/postings.py 3146342482
verify app/services/ledger/postings_legacy.py 3982674387
verify app/services/ledger/reconcile.py 270085780
verify app/services/quota/__init__.py 1015210046
verify app/services/quota/meter.py 3029489853
verify app/services/quota/policy.py 347403919
verify app/services/quota/reset.py 2989651325
verify app/signals/__init__.py 3825551858
verify app/signals/dispatch.py 4054295985
verify app/signals/quota_signals.py 666997491
verify app/signals/registry.py 333310184
verify app/storage/__init__.py 2986927796
verify app/storage/blobs.py 2545615334
verify app/storage/index.py 4154229990
verify app/storage/journal.py 3485028093
verify app/storage/ledger_writer.py 600306151
verify app/storage/legacy_journal.py 2993030224
verify app/storage/migrations.py 4246703552
verify app/tasks/__init__.py 2171532614
verify app/tasks/cleanup.py 3008339358
verify app/tasks/hourly.py 2497496167
verify app/tasks/nightly.py 3066813001
verify app/tasks/reconcile.py 877024282
verify config/templates.tsv 2208691469
verify docs/architecture.md 631183077
verify docs/modules/channels.md-3 1628445772
verify docs/modules/commands.md-10 914286391
verify docs/modules/commands.md-11 574008900
verify docs/modules/commands.md-9 774804192
verify docs/modules/events.md-1 1219686230
verify docs/modules/http.md-0 3175158559
verify docs/modules/ledger.md-8 1047702955
verify docs/modules/legacy.md-7 3391306133
verify docs/modules/notify.md-2 3454170204
verify docs/modules/render.md-5 1858550081
verify docs/modules/scheduler.md-4 4091197659
verify docs/modules/tasks.md-6 1557813324
verify docs/runbooks/alder-1.md 2796799610
verify docs/runbooks/birch-0.md 4091779451
verify docs/runbooks/comet-4.md 1958088386
verify docs/runbooks/cypress-2.md 195610499
verify docs/runbooks/gravel-3.md 363519346
verify docs/runbooks/umber-5.md 2588766157
verify templates/html/invoice-document.html 2945137684
verify templates/html/invoice-print.html 27873318
verify templates/html/invoice.html 833834289
verify templates/html/order.html 882382332
verify templates/legacy/invoice_pdf.tpl 2445317587
verify templates/pdf/invoice-2026.tpl 2430606059
verify templates/pdf/invoice.tpl 4049429923
verify templates/pdf/receipt.tpl 3094092134
verify tests/test_anvil_5.py 2588530847
verify tests/test_ashen_10.py 990167699
verify tests/test_balsa_1.py 3586997796
verify tests/test_bronze_11.py 3849901496
verify tests/test_cairn_16.py 286015942
verify tests/test_gravel_15.py 1829639998
verify tests/test_hazel_9.py 955098425
verify tests/test_heron_8.py 3534012142
verify tests/test_ingot_17.py 3608906923
verify tests/test_jasper_3.py 922115269
verify tests/test_kestrel_13.py 1523430455
verify tests/test_kestrel_7.py 1937471844
verify tests/test_lumen_14.py 2090633004
verify tests/test_meadow_2.py 707885621
verify tests/test_orchard_0.py 1269660167
verify tests/test_osprey_4.py 3811184532
verify tests/test_plover_6.py 2527710025
verify tests/test_timber_19.py 3608523050
verify tests/test_walnut_12.py 724774300
verify tests/test_walnut_18.py 4069285492
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\160\144\146\057\151\156\166\157\151\143\145\055\062\060\062\066\056\164\160\154'
echo "report ok"
