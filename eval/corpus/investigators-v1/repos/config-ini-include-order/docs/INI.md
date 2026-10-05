# INI loading rules

`app.ini` is read first. Every `include = <glob>` line in it is expanded
relative to the repository root. The matched files are sorted by file name and
applied in that order, **after** `app.ini`'s own keys, so a key set in a later
file replaces the same key from an earlier file or from `app.ini` itself.

Only files whose name ends in `.ini` are matched by the include globs;
anything else in a drop-in directory is ignored regardless of its contents.
