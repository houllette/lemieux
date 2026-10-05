#!/bin/sh
# Grader for datajoin-skip-level-manager: every fixture file must be unchanged and the
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
verify README.md 613858715
verify docs/glossary.md 4201347996
verify docs/handbook/leave-of-absence.md 4226486589
verify docs/handbook/reporting-lines.md 477499054
verify docs/handbook/transfers.md 3012689995
verify docs/orgchart-2025.md 2375137498
verify docs/teams/catalog.md 956815689
verify docs/teams/ledger.md 2217164390
verify docs/teams/ops.md 3241921276
verify docs/teams/platform.md 622588478
verify docs/teams/search.md 23132016
verify org/archive/assignments-2022-flat.csv 2521657363
verify org/archive/assignments-2023-flat.csv 181168016
verify org/assignments/2024/assignments-00.csv 2870459267
verify org/assignments/2024/assignments-01.csv 2861362754
verify org/assignments/2024/assignments-02.csv 476374486
verify org/assignments/2024/assignments-03.csv 2608598403
verify org/assignments/2024/assignments-04.csv 1055136765
verify org/assignments/2024/assignments-05.csv 1153302555
verify org/assignments/2024/assignments-06.csv 3688466894
verify org/assignments/2024/assignments-07.csv 1374690040
verify org/assignments/2024/assignments-08.csv 1159417677
verify org/assignments/2024/assignments-09.csv 634441619
verify org/assignments/2024/assignments-10.csv 333495492
verify org/assignments/2024/assignments-11.csv 1191244192
verify org/assignments/2024/assignments-12.csv 3251044822
verify org/assignments/2024/assignments-13.csv 2601788973
verify org/assignments/2024/assignments-14.csv 38274475
verify org/assignments/2024/assignments-15.csv 2560396912
verify org/assignments/2024/assignments-16.csv 3272727100
verify org/assignments/2024/assignments-17.csv 2414581632
verify org/assignments/2024/assignments-18.csv 2957603113
verify org/assignments/2024/assignments-19.csv 4244642452
verify org/assignments/2025/assignments-00.csv 44289579
verify org/assignments/2025/assignments-01.csv 3348333924
verify org/assignments/2025/assignments-02.csv 2780731098
verify org/assignments/2025/assignments-03.csv 471052165
verify org/assignments/2025/assignments-04.csv 720167232
verify org/assignments/2025/assignments-05.csv 3677240564
verify org/assignments/2025/assignments-06.csv 3167213454
verify org/assignments/2025/assignments-07.csv 2105805814
verify org/assignments/2025/assignments-08.csv 1796181027
verify org/assignments/2025/assignments-09.csv 1698270724
verify org/assignments/2025/assignments-10.csv 1588057772
verify org/assignments/2025/assignments-11.csv 1365825058
verify org/assignments/2025/assignments-12.csv 931588498
verify org/assignments/2025/assignments-13.csv 1382669618
verify org/assignments/2025/assignments-14.csv 3642205762
verify org/assignments/2025/assignments-15.csv 409224938
verify org/assignments/2025/assignments-16.csv 3732233437
verify org/assignments/2025/assignments-17.csv 3183039293
verify org/assignments/2025/assignments-18.csv 883507671
verify org/assignments/2025/assignments-19.csv 4234233189
verify org/assignments/2026/assignments-00.csv 3726384310
verify org/assignments/2026/assignments-01.csv 2420937544
verify org/assignments/2026/assignments-02.csv 2750381894
verify org/assignments/2026/assignments-03.csv 2984384645
verify org/assignments/2026/assignments-04.csv 1507935175
verify org/assignments/2026/assignments-05.csv 3397725852
verify org/assignments/2026/assignments-06.csv 3170739885
verify org/assignments/2026/assignments-07.csv 546770458
verify org/assignments/2026/assignments-08.csv 322381665
verify org/assignments/2026/assignments-09.csv 3791120345
verify org/assignments/2026/assignments-10.csv 4127426806
verify org/assignments/2026/assignments-11.csv 3838966240
verify org/assignments/2026/assignments-12.csv 3532348309
verify org/assignments/2026/assignments-13.csv 624492592
verify org/assignments/2026/assignments-14.csv 1311861048
verify org/assignments/2026/assignments-15.csv 2829023341
verify org/assignments/2026/assignments-16.csv 2675686718
verify org/assignments/2026/assignments-17.csv 3367779142
verify org/assignments/2026/assignments-18.csv 3832872522
verify org/assignments/2026/assignments-19.csv 4029676743
verify org/departments/README.md 2231052531
verify org/departments/heads.csv 2571074579
verify org/reviews/2025/catalog.md 1749898780
verify org/reviews/2025/ledger.md 2486286368
verify org/reviews/2025/ops.md 3151497354
verify org/reviews/2025/platform.md 494217609
verify org/reviews/2025/search.md 2583740535
verify people/people-00.csv 1443910764
verify people/people-01.csv 1188911106
verify people/people-02.csv 952271725
verify people/people-03.csv 333657473
verify people/people-04.csv 2332301283
verify people/people-05.csv 1269170531
verify people/people-06.csv 3580656288
verify people/people-07.csv 2982228703
verify people/people-08.csv 1111003470
verify people/people-09.csv 3484626324
verify people/people-10.csv 1592530916
verify people/people-11.csv 1035457481
verify people/people-12.csv 2840976958
verify people/people-13.csv 1570699499
verify people/people-14.csv 959822729
verify people/people-15.csv 1634581379
verify people/people-16.csv 603127949
verify people/people-17.csv 928238028
verify people/people-18.csv 809177968
verify people/people-19.csv 3116663583
verify people/people-20.csv 2847550794
verify people/people-21.csv 814880571
verify people/people-22.csv 87540223
[ -n "$answer" ] || fail "no answer was reported"
expect 1 '\151\163\164\152\157\162\040\142\145\154\162\141\156'
echo "report ok"
