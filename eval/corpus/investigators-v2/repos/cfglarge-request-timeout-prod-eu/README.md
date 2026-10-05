# Configuration tree

The loader assembles one flat set of `section.key` values per deployment
target. The rules below are the whole algorithm; nothing else contributes.

1. `deploy/<env>/<region>/target.conf` names the `profile` and an optional
   comma-separated list of `overlays`.
2. Profiles live in `profiles/<name>.conf`. A profile whose first line is
   `inherits = <parent>` is applied after its parent; the chain is resolved
   root first, so a child's values win over its ancestors.
3. Inside any file, statements apply top to bottom. `include =
   includes/<name>.conf` splices `config/includes/<name>.conf` in at that
   point: a key set above the include is overridden by the included file,
   and a key set below the include overrides it.
4. Overlays (`config/overlays/<name>.conf`) apply after the whole profile
   chain, in the order the target lists them.
5. `deploy/<env>/<region>/env.list` applies after the overlays. A line
   `SECTION__KEY=value` sets `section.key`; every other line is a plain
   variable used only for `${VAR}` substitution.
6. `policy/<env>/locked.conf` applies last. A key listed there takes the
   policy file's value for every target of that environment, whatever any
   other layer says.
7. Files under `config/archive/` and any file ending in `.disabled` are
   never read.
8. A value of the form `@sinks/<name>` names `config/sinks/<name>.conf`,
   whose `host =` is a host id resolved through `inventory/hosts.tsv`.
   `host_legacy` is the id the sink used before the collector migration.
9. `${VAR}` in a value is substituted from the target's env.list after all
   layers are applied.

`docs/keys-reference.md` documents every key and the loader's compiled-in
fallback, which is only used when no layer at all sets the key.
