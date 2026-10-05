#!/bin/sh
# Grader for datajoin-sensor-breach-count: every fixture file must be unchanged and the
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
verify README.md 15063325
verify calibration/README.md 778324707
verify calibration/offsets.csv 2618772464
verify docs/glossary.md 3529286921
verify readings/all-sites-flat.csv 752563348
verify readings/sn-07c13/2026-06-05.csv 2949298969
verify readings/sn-07c13/2026-06-06.csv 1957925114
verify readings/sn-07c13/2026-06-07.csv 3831289952
verify readings/sn-07c13/2026-06-08.csv 1098891982
verify readings/sn-07c13/2026-06-09.csv 50544589
verify readings/sn-07c13/2026-06-10.csv 3587510178
verify readings/sn-07c13/2026-06-11.csv 2033311612
verify readings/sn-07c13/2026-06-12.csv 190406121
verify readings/sn-07c13/2026-06-13.csv 1465944723
verify readings/sn-07c13/2026-06-14.csv 2997952167
verify readings/sn-07c13/2026-06-15.csv 3819548704
verify readings/sn-07c13/2026-06-16.csv 1865472048
verify readings/sn-07c13/2026-06-17.csv 956012044
verify readings/sn-0e39f/2026-06-06.csv 2457085930
verify readings/sn-0f090/2026-06-07.csv 3809899534
verify readings/sn-12120/2026-06-05.csv 1265738560
verify readings/sn-12120/2026-06-06.csv 502693932
verify readings/sn-12120/2026-06-07.csv 2513956039
verify readings/sn-12120/2026-06-08.csv 2403380955
verify readings/sn-12120/2026-06-09.csv 1032462342
verify readings/sn-12120/2026-06-10.csv 3581209342
verify readings/sn-12120/2026-06-11.csv 3013971968
verify readings/sn-12120/2026-06-12.csv 3133347442
verify readings/sn-12120/2026-06-13.csv 3484375289
verify readings/sn-12120/2026-06-14.csv 2676611070
verify readings/sn-12120/2026-06-15.csv 876674559
verify readings/sn-12120/2026-06-16.csv 658514238
verify readings/sn-12120/2026-06-17.csv 27880466
verify readings/sn-1342a/2026-06-05.csv 1503522640
verify readings/sn-1342a/2026-06-06.csv 1138404679
verify readings/sn-1525a/2026-06-06.csv 4158772648
verify readings/sn-1525a/2026-06-07.csv 1647177027
verify readings/sn-1525a/2026-06-10.csv 2722322932
verify readings/sn-1525a/2026-06-13.csv 867773981
verify readings/sn-1525a/2026-06-15.csv 2130707947
verify readings/sn-152c8/2026-06-05.csv 1373857524
verify readings/sn-1597d/2026-06-06.csv 3619810252
verify readings/sn-1597d/2026-06-07.csv 3296078788
verify readings/sn-1597d/2026-06-08.csv 1363666747
verify readings/sn-1597d/2026-06-14.csv 3890565326
verify readings/sn-1597d/2026-06-16.csv 537830486
verify readings/sn-1ae14/2026-06-05.csv 4273273866
verify readings/sn-1ae14/2026-06-06.csv 3464195013
verify readings/sn-1ae14/2026-06-10.csv 567254357
verify readings/sn-1ae14/2026-06-13.csv 3908961364
verify readings/sn-1ae14/2026-06-14.csv 892229193
verify readings/sn-1ae14/2026-06-15.csv 3599280330
verify readings/sn-1b61a/2026-06-06.csv 2472565584
verify readings/sn-1b61a/2026-06-07.csv 647429662
verify readings/sn-1b61a/2026-06-08.csv 1067878409
verify readings/sn-1b61a/2026-06-12.csv 1122855376
verify readings/sn-1b61a/2026-06-13.csv 714057156
verify readings/sn-1b61a/2026-06-15.csv 755603693
verify readings/sn-221f3/2026-06-06.csv 2188310479
verify readings/sn-221f3/2026-06-12.csv 3098856371
verify readings/sn-221f3/2026-06-15.csv 3386004453
verify readings/sn-221f3/2026-06-16.csv 379688921
verify readings/sn-328db/2026-06-07.csv 117955847
verify readings/sn-328db/2026-06-11.csv 2326486757
verify readings/sn-54a4d/2026-06-07.csv 3271190000
verify readings/sn-54a4d/2026-06-08.csv 3050179606
verify readings/sn-54a4d/2026-06-15.csv 2310007661
verify readings/sn-54a4d/2026-06-16.csv 2408484421
verify readings/sn-68fb8/2026-06-07.csv 2744002974
verify readings/sn-68fb8/2026-06-08.csv 1451748347
verify readings/sn-68fb8/2026-06-13.csv 4063304714
verify readings/sn-74a28/2026-06-05.csv 3007231898
verify readings/sn-74a28/2026-06-06.csv 2199398122
verify readings/sn-74a28/2026-06-07.csv 13541800
verify readings/sn-74a28/2026-06-08.csv 1387607703
verify readings/sn-74a28/2026-06-09.csv 1117609700
verify readings/sn-74a28/2026-06-10.csv 2931016704
verify readings/sn-74a28/2026-06-11.csv 2804977265
verify readings/sn-74a28/2026-06-12.csv 2042269658
verify readings/sn-74a28/2026-06-13.csv 2391024635
verify readings/sn-74a28/2026-06-14.csv 4197813007
verify readings/sn-74a28/2026-06-15.csv 3771404897
verify readings/sn-74a28/2026-06-16.csv 1920684168
verify readings/sn-74a28/2026-06-17.csv 439788313
verify readings/sn-7b544/2026-06-15.csv 769619179
verify readings/sn-8ecc9/2026-06-06.csv 1580446950
verify readings/sn-8ecc9/2026-06-08.csv 3318327956
verify readings/sn-8ecc9/2026-06-16.csv 1104104756
verify readings/sn-8f3c8/2026-06-07.csv 1700581417
verify readings/sn-8f3c8/2026-06-11.csv 469293696
verify readings/sn-8f3c8/2026-06-14.csv 3405205362
verify readings/sn-9514d/2026-06-05.csv 1243513167
verify readings/sn-9514d/2026-06-07.csv 696821577
verify readings/sn-9514d/2026-06-08.csv 3771003509
verify readings/sn-9514d/2026-06-13.csv 1250877378
verify readings/sn-9514d/2026-06-17.csv 3816810647
verify readings/sn-9f90d/2026-06-05.csv 2805081043
verify readings/sn-9f90d/2026-06-07.csv 3787404048
verify readings/sn-9f90d/2026-06-08.csv 571340472
verify readings/sn-9f90d/2026-06-14.csv 919677135
verify readings/sn-ac847/2026-06-05.csv 3849563111
verify readings/sn-ac847/2026-06-06.csv 4268796247
verify readings/sn-ac847/2026-06-07.csv 466283184
verify readings/sn-ac847/2026-06-08.csv 3498247840
verify readings/sn-ac847/2026-06-09.csv 3964859448
verify readings/sn-ac847/2026-06-10.csv 2133283497
verify readings/sn-ac847/2026-06-11.csv 968349301
verify readings/sn-ac847/2026-06-12.csv 706180640
verify readings/sn-ac847/2026-06-13.csv 2067142947
verify readings/sn-ac847/2026-06-14.csv 2781707580
verify readings/sn-ac847/2026-06-15.csv 3531726186
verify readings/sn-ac847/2026-06-16.csv 3880083587
verify readings/sn-ac847/2026-06-17.csv 2074025829
verify readings/sn-acb8a/2026-06-07.csv 3200757316
verify readings/sn-acb8a/2026-06-16.csv 2035387365
verify readings/sn-e1567/2026-06-06.csv 677680839
verify readings/sn-e1567/2026-06-08.csv 2779211915
verify readings/sn-e1567/2026-06-11.csv 1931088106
verify readings/sn-e1567/2026-06-13.csv 2357518543
verify readings/sn-ee3b2/2026-06-06.csv 321768543
verify readings/sn-ee3b2/2026-06-07.csv 3278323983
verify readings/sn-ee3b2/2026-06-14.csv 4015021662
verify readings/sn-ee3b2/2026-06-17.csv 1260623681
verify sites/site-heron.json 297260006
verify sites/site-linden.json 1997896887
verify sites/site-meadow.json 3676389612
verify sites/site-onyx.json 2728809025
verify sites/site-umber.json 2862099367
verify sites/site-wicker.json 754525891
verify thresholds/changes.csv 1431840635
verify thresholds/sites.csv 1936374713
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\061\065\062'
echo "report ok"
