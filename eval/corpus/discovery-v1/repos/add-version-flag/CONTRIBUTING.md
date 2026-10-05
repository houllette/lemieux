# Contributing

Small project, few rules, but they are checked at review:

1. Every user-visible change to `bin/tidy` bumps the patch component of
   `VERSION` (`MAJOR.MINOR.PATCH`); the release script tags whatever is in
   that file. `bin/tidy --version` and the docs must agree with it.
2. Every option handled in `bin/tidy` is listed both in the script's usage
   text and in the table in `docs/OPTIONS.md`, in the same spelling.
3. Run `sh scripts/lint.sh` before submitting. It must print `lint ok`;
   it enforces rule 2.
4. Run `sh tests/run.sh`; it must pass.
