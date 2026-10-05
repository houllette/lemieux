# record sync cli

`bin/sync` pushes local records to the remote store. Exit statuses are defined
in `lib/codes.sh`; sites may override them with `lib/codes.local.sh`, which is
loaded after the defaults when present. `docs/CLI.md` is the user-facing
description.
