# Repository rules

`main.json` and `releases.json` are the reviewed payloads for the active GitHub
rulesets. GitHub supplies response-only IDs and defaults; those are not inputs.

The main gate requires every job in CI and Public readiness, including coverage,
dependency security and stock learning replay. Checks must originate from GitHub
Actions (integration 15368), and the branch must be current before a squash
merge. Pull requests and resolved conversations are required. Zero approving
reviews keeps a sole maintainer able to merge their own work. There are no bypass
actors, force pushes or branch deletion.

Version tags matching `v*` may be created by repository writers, as the release
driver requires. They cannot be moved or deleted, with no bypass. Release signing
and source/archive qualification remain separate requirements.

The active IDs are 26232154 (main) and 26232161 (version tags). An administrator
applies reviewed changes with:

```sh
gh api --method PUT repos/houllette/lemieux/rulesets/26232154 --input .github/rulesets/main.json
gh api --method PUT repos/houllette/lemieux/rulesets/26232161 --input .github/rulesets/releases.json
gh api repos/houllette/lemieux/rules/branches/main
gh api repos/houllette/lemieux/rulesets/26232161
```

`test/repository_rules_test.exs` expands workflow matrix names and checks that
the main payload requires every CI/Public readiness job. A renamed or added job
must update both the payload and the live ruleset in the same change. The
dependency-submission workflow is advisory and is not a required check.
