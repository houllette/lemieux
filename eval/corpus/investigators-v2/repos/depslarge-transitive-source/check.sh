#!/bin/sh
# Grader for depslarge-transitive-source: every fixture file must be unchanged and the
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
verify README.md 1709607866
verify build/build.sh 347077456
verify build/logs/resolver-last.log 3370470068
verify build/profiles/dev.env 3337345287
verify build/profiles/hardened.env 1248484679
verify build/profiles/prod.env 1624539185
verify build/profiles/release.env 638833588
verify build/versions.env 2241485167
verify docs/BUILD.md 2371517363
verify docs/packages/argsplit.md 3163418497
verify docs/packages/blobstore.md 1036702567
verify docs/packages/cipherbox.md 4279134516
verify docs/packages/clockwork.md 2012633338
verify docs/packages/colorize.md 3218058535
verify docs/packages/csvfast.md 2974183101
verify docs/packages/fsync.md 1068625121
verify docs/packages/hashfold.md 4180371699
verify docs/packages/httpkit.md 3694131377
verify docs/packages/ledgercore.md 660793205
verify docs/packages/metricsd.md 1403648580
verify docs/packages/pemparse.md 2143240711
verify docs/packages/queuelet.md 856539266
verify docs/packages/ratelimit.md 3446506885
verify docs/packages/retryable.md 304391779
verify docs/packages/tabulate2.md 439186898
verify docs/packages/tinyjson.md 2869212646
verify docs/packages/tomlet.md 140118212
verify docs/packages/tracekit.md 2165967486
verify docs/packages/yamlish.md 3897509788
verify forks/argsplit-lite/MANIFEST 683725277
verify forks/argsplit-lite/VERSION 1507524079
verify forks/argsplit-lite/include/argsplit.h 1120372869
verify forks/argsplit-lite/src/delta_1.py 2333262371
verify forks/argsplit-lite/src/mica_2.py 1792759511
verify forks/argsplit-lite/src/rowan_0.py 1957924758
verify forks/ledgercore-patched/MANIFEST 1445045855
verify forks/ledgercore-patched/VERSION 4185124769
verify forks/ledgercore-patched/include/ledgercore.h 2394038772
verify forks/ledgercore-patched/src/delta_2.py 994806131
verify forks/ledgercore-patched/src/larch_1.py 1010593173
verify forks/ledgercore-patched/src/orchard_0.py 4228093608
verify forks/ratelimit-patched/MANIFEST 1412883930
verify forks/ratelimit-patched/VERSION 2979405089
verify forks/ratelimit-patched/include/ratelimit.h 3738779842
verify forks/ratelimit-patched/src/kestrel_2.py 838471023
verify forks/ratelimit-patched/src/nettle_1.py 3383874006
verify forks/ratelimit-patched/src/pewter_0.py 1824991061
verify forks/yamlish-fast/MANIFEST 3483386797
verify forks/yamlish-fast/VERSION 3888777581
verify forks/yamlish-fast/include/yamlish.h 1602448070
verify forks/yamlish-fast/src/cedar_2.py 2682549502
verify forks/yamlish-fast/src/dune_0.py 832161781
verify forks/yamlish-fast/src/falcon_1.py 3550822337
verify images/api/Buildfile 1462917854
verify images/api/notes.md 2137466022
verify images/cli/Buildfile 201525176
verify images/cli/notes.md 1304954705
verify images/gateway/Buildfile 3788555380
verify images/gateway/notes.md 3584184158
verify images/worker/Buildfile 2604175843
verify images/worker/notes.md 3476801581
verify locks/dev/admin.lock 3018919889
verify locks/dev/api.lock 2701237159
verify locks/dev/cli.lock 4210569546
verify locks/dev/exporter.lock 2268272385
verify locks/dev/gateway.lock 3438089796
verify locks/dev/ledger.lock 1544206037
verify locks/dev/search.lock 354577416
verify locks/dev/worker.lock 857566016
verify locks/hardened/admin.lock 4116051567
verify locks/hardened/api.lock 1613585826
verify locks/hardened/cli.lock 3410859819
verify locks/hardened/exporter.lock 2361378033
verify locks/hardened/gateway.lock 2156903295
verify locks/hardened/ledger.lock 2917452118
verify locks/hardened/search.lock 2355026110
verify locks/hardened/worker.lock 1146305553
verify locks/p2/admin.lock 818129485
verify locks/p2/api.lock 2897616856
verify locks/p2/cli.lock 3747197384
verify locks/p2/exporter.lock 4268638479
verify locks/p2/gateway.lock 3843456743
verify locks/p2/ledger.lock 2060791309
verify locks/p2/search.lock 1903491531
verify locks/p2/worker.lock 736905957
verify locks/prod/admin.lock 93721558
verify locks/prod/api.lock 1726036352
verify locks/prod/cli.lock 840311842
verify locks/prod/exporter.lock 1416690926
verify locks/prod/gateway.lock 2548897813
verify locks/prod/ledger.lock 207586687
verify locks/prod/search.lock 3957901695
verify locks/prod/worker.lock 950901394
verify manifests/admin.deps 175935353
verify manifests/api.deps 4118770384
verify manifests/cli.deps 3258812565
verify manifests/exporter.deps 4122480786
verify manifests/gateway.deps 975987899
verify manifests/ledger.deps 2999136465
verify manifests/search.deps 2091710367
verify manifests/toolchain.manifest 14798839
verify manifests/worker.deps 3597212808
verify tools/badger-0.sh 1820221545
verify tools/comet-5.sh 3050766816
verify tools/dapple-3.sh 3784148891
verify tools/ember-1.sh 1231843868
verify tools/lichen-2.sh 3406648773
verify tools/verdant-4.sh 1445286186
verify vendor/httpkit/4.6.8/CHANGES 3796207720
verify vendor/httpkit/4.6.8/MANIFEST 3832198230
verify vendor/httpkit/4.6.8/VERSION 4195671996
verify vendor/httpkit/4.6.8/include/httpkit.h 3552283937
verify vendor/httpkit/4.6.8/src/anvil_0.py 2572443165
verify vendor/httpkit/4.6.8/src/jasper_1.py 3346740056
verify vendor/httpkit/4.6.8/src/quill_2.py 2911410611
verify vendor/ledgercore/3.3.14/CHANGES 3077839220
verify vendor/ledgercore/3.3.14/MANIFEST 1926079888
verify vendor/ledgercore/3.3.14/VERSION 705889076
verify vendor/ledgercore/3.3.14/include/ledgercore.h 2196020126
verify vendor/ledgercore/3.3.14/src/lumen_1.py 3122372744
verify vendor/ledgercore/3.3.14/src/reed_2.py 2634460763
verify vendor/ledgercore/3.3.14/src/saffron_0.py 3617018673
verify vendor/queuelet/1.4.1/CHANGES 1375024191
verify vendor/queuelet/1.4.1/MANIFEST 177317127
verify vendor/queuelet/1.4.1/VERSION 299372027
verify vendor/queuelet/1.4.1/include/queuelet.h 1193379179
verify vendor/queuelet/1.4.1/src/ochre_0.py 4226093270
verify vendor/queuelet/1.4.1/src/orchard_1.py 3068623644
verify vendor/queuelet/1.4.1/src/pebble_2.py 29301687
verify vendor/queuelet/1.9.8/CHANGES 3304187777
verify vendor/queuelet/1.9.8/MANIFEST 1007519097
verify vendor/queuelet/1.9.8/VERSION 919938636
verify vendor/queuelet/1.9.8/include/queuelet.h 4288940682
verify vendor/queuelet/1.9.8/src/larch_0.py 1501060077
verify vendor/queuelet/1.9.8/src/marrow_2.py 1596645164
verify vendor/queuelet/1.9.8/src/osprey_1.py 1904618205
verify vendor/ratelimit/1.8.5/CHANGES 3538042986
verify vendor/ratelimit/1.8.5/MANIFEST 2913809855
verify vendor/ratelimit/1.8.5/VERSION 2007448418
verify vendor/ratelimit/1.8.5/include/ratelimit.h 602571811
verify vendor/ratelimit/1.8.5/src/coral_2.py 708496763
verify vendor/ratelimit/1.8.5/src/hollow_1.py 3064108917
verify vendor/ratelimit/1.8.5/src/sorrel_0.py 2299605736
verify vendor/retryable/3.12.12/CHANGES 1311026610
verify vendor/retryable/3.12.12/MANIFEST 532676827
verify vendor/retryable/3.12.12/VERSION 37082835
verify vendor/retryable/3.12.12/include/retryable.h 1402405229
verify vendor/retryable/3.12.12/src/crag_0.py 583169184
verify vendor/retryable/3.12.12/src/larch_1.py 409100823
verify vendor/retryable/3.12.12/src/thistle_2.py 1561159204
verify vendor/tabulate2/3.11.20/CHANGES 2738942773
verify vendor/tabulate2/3.11.20/MANIFEST 2145189255
verify vendor/tabulate2/3.11.20/VERSION 1284188731
verify vendor/tabulate2/3.11.20/include/tabulate2.h 261648179
verify vendor/tabulate2/3.11.20/src/lichen_0.py 3710952273
verify vendor/tabulate2/3.11.20/src/moss_2.py 2662670822
verify vendor/tabulate2/3.11.20/src/sedge_1.py 3399351730
verify vendor/tinyjson/0.9.2/CHANGES 2422659945
verify vendor/tinyjson/0.9.2/MANIFEST 3925090067
verify vendor/tinyjson/0.9.2/VERSION 1962308459
verify vendor/tinyjson/0.9.2/include/tinyjson.h 3320947729
verify vendor/tinyjson/0.9.2/src/aster_1.py 2597357692
verify vendor/tinyjson/0.9.2/src/ingot_2.py 434969864
verify vendor/tinyjson/0.9.2/src/tundra_0.py 2043840829
verify vendor/tracekit/1.4.15/CHANGES 3616912778
verify vendor/tracekit/1.4.15/MANIFEST 1593892342
verify vendor/tracekit/1.4.15/VERSION 3713021007
verify vendor/tracekit/1.4.15/include/tracekit.h 2625712025
verify vendor/tracekit/1.4.15/src/nettle_2.py 613034652
verify vendor/tracekit/1.4.15/src/osprey_0.py 2831716832
verify vendor/tracekit/1.4.15/src/pewter_1.py 2444675026
verify workspace.deps 3078208558
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\154\145\144\147\145\162\143\157\162\145'
expect 2 '\060\056\071\056\064'
echo "report ok"
