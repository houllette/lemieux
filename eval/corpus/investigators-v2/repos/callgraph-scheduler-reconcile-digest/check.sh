#!/bin/sh
# Grader for callgraph-scheduler-reconcile-digest: every fixture file must be unchanged and the
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
verify README.md 1808166614
verify app/__init__.py 944556697
verify app/cli/__init__.py 2519210452
verify app/cli/main.py 2182981291
verify app/cli/output.py 248485703
verify app/cli/registry.py 3868267443
verify app/commands/__init__.py 3940485025
verify app/commands/export.py 2247478421
verify app/commands/import_.py 3438658905
verify app/commands/prune.py 4086783167
verify app/commands/reconcile.py 2322898815
verify app/commands/rollup.py 3393314873
verify app/commands/status.py 997381961
verify app/core/__init__.py 1119839607
verify app/core/clock.py 2464464112
verify app/core/config.py 2118642683
verify app/core/container.py 3024496729
verify app/core/errors.py 2006919588
verify app/core/logging_setup.py 1258844688
verify app/core/retry.py 1372406491
verify app/events/__init__.py 2278297817
verify app/events/bus.py 3253905742
verify app/events/replay.py 2504513385
verify app/events/subscriptions.py 1228524268
verify app/generated/__init__.py 4294967295
verify app/generated/constants.py 1674322783
verify app/handlers/__init__.py 3719374476
verify app/handlers/cancellations.py 2484845699
verify app/handlers/payments.py 928767390
verify app/handlers/refunds.py 1974429640
verify app/handlers/shipments.py 340210301
verify app/hashing/__init__.py 2280360862
verify app/hashing/crc_fold.py 3442298026
verify app/hashing/fold64.py 3348582051
verify app/hashing/registry.py 613650948
verify app/hashing/sha_like.py 1103630004
verify app/http/__init__.py 2248361807
verify app/http/controllers.py 2559578632
verify app/http/middleware.py 195311910
verify app/http/responses.py 4171748689
verify app/http/routes.py 2840114747
verify app/legacy/__init__.py 133767244
verify app/legacy/audit.py 2265718169
verify app/legacy/handlers.py 2565563248
verify app/legacy/hashing.py 3331404840
verify app/legacy/notify.py 1539902484
verify app/legacy/renderers.py 781914616
verify app/models/__init__.py 1416109836
verify app/models/customer.py 3349969603
verify app/models/invoice.py 99397419
verify app/models/ledger_entry.py 567095249
verify app/models/order.py 1389316594
verify app/models/quota.py 4232087474
verify app/models/snapshot.py 1176620049
verify app/notify/__init__.py 3019589984
verify app/notify/backoff.py 699785752
verify app/notify/channels/__init__.py 3835347059
verify app/notify/channels/chat.py 3486463460
verify app/notify/channels/mail.py 3406753484
verify app/notify/channels/pager.py 294792540
verify app/notify/channels/pager_v2.py 2927106543
verify app/notify/channels/webhook.py 827865833
verify app/notify/router.py 2829341065
verify app/notify/templates.py 4229369485
verify app/render/__init__.py 4145259953
verify app/render/engine.py 3977123440
verify app/render/filters.py 3814218372
verify app/render/pdf_shim.py 4134510592
verify app/render/registry.py 1422627552
verify app/scheduler/__init__.py 3361350856
verify app/scheduler/cron.py 540163586
verify app/scheduler/jobs.py 3160322179
verify app/scheduler/leases.py 188579002
verify app/services/audit/__init__.py 1148846154
verify app/services/audit/filters.py 3054417638
verify app/services/audit/redaction.py 2308133228
verify app/services/audit/sink_v1.py 4109862666
verify app/services/audit/sink_v2.py 2623517532
verify app/services/ledger/__init__.py 2598886985
verify app/services/ledger/balances.py 600259923
verify app/services/ledger/postings.py 1214175637
verify app/services/ledger/postings_legacy.py 279559880
verify app/services/ledger/reconcile.py 1744780907
verify app/services/quota/__init__.py 1015210046
verify app/services/quota/meter.py 93387851
verify app/services/quota/policy.py 4112730664
verify app/services/quota/reset.py 2446961616
verify app/signals/__init__.py 3825551858
verify app/signals/dispatch.py 4237464840
verify app/signals/quota_signals.py 2892119015
verify app/signals/registry.py 710454550
verify app/storage/__init__.py 2986927796
verify app/storage/blobs.py 1354324297
verify app/storage/index.py 1884453230
verify app/storage/journal.py 2527015925
verify app/storage/ledger_writer.py 3701328727
verify app/storage/legacy_journal.py 196272745
verify app/storage/migrations.py 4285629726
verify app/tasks/__init__.py 2171532614
verify app/tasks/cleanup.py 213433426
verify app/tasks/hourly.py 2481589045
verify app/tasks/nightly.py 225259982
verify app/tasks/reconcile.py 2935366034
verify config/schedule.tsv 633725728
verify config/settings.conf 1571259139
verify config/settings.example.conf 3459945941
verify docs/architecture.md 1663871905
verify docs/modules/audit.md-1 3748662804
verify docs/modules/audit.md-11 3859875291
verify docs/modules/channels.md-0 3759480021
verify docs/modules/core.md-9 501593114
verify docs/modules/handlers.md-5 1443482632
verify docs/modules/hashing.md-10 1507391366
verify docs/modules/legacy.md-3 3264547857
verify docs/modules/legacy.md-7 568364893
verify docs/modules/notify.md-6 58670084
verify docs/modules/quota.md-4 3721082733
verify docs/modules/render.md-8 211583795
verify docs/modules/scheduler.md-2 1729917112
verify docs/runbooks/canvas-1.md 3863078046
verify docs/runbooks/comet-0.md 1211773358
verify docs/runbooks/dapple-5.md 2616642128
verify docs/runbooks/plover-3.md 335425005
verify docs/runbooks/rowan-2.md 718610908
verify docs/runbooks/tallow-4.md 1381598719
verify tests/test_anvil_17.py 2154863192
verify tests/test_atlas_0.py 2216555750
verify tests/test_bison_8.py 513043308
verify tests/test_bronze_5.py 3074240170
verify tests/test_cedar_9.py 2125856866
verify tests/test_cinder_3.py 2800765745
verify tests/test_crag_18.py 4122907661
verify tests/test_fathom_10.py 3689940922
verify tests/test_fennel_16.py 2198022963
verify tests/test_fjord_1.py 2015163757
verify tests/test_garnet_7.py 2086391641
verify tests/test_granite_6.py 1932736780
verify tests/test_jasper_15.py 747454235
verify tests/test_lantern_4.py 424989168
verify tests/test_lichen_11.py 2235031053
verify tests/test_pebble_12.py 912951452
verify tests/test_tundra_19.py 946129781
verify tests/test_umber_14.py 350891430
verify tests/test_umber_2.py 1665090054
verify tests/test_willow_13.py 1823112840
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\144\151\147\145\163\164\137\146\157\154\144\066\064'
expect 2 '\141\160\160\057\150\141\163\150\151\156\147\057\146\157\154\144\066\064\056\160\171'
echo "report ok"
