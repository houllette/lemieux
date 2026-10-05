# Building

- `build/build.sh <component> [profile]` builds one workspace member.
- The profile file `build/profiles/<profile>.env` sets `LOCK_DIR`, the
  directory whose `<component>.lock` is the authoritative pin set for that
  build. Nothing else selects a lock.
- Replacement precedence: a `[replace]` in `workspace.deps` overrides a
  `[replace]` in `manifests/<component>.deps`, which overrides the lock. A
  replaced package is compiled from the directory named, at the version in
  that directory's `VERSION` file; the lock's pin for it is ignored.
- Lock rows are `name version digest requested_by`; `requested_by` is
  `direct` for a manifest entry, otherwise the package that pulled it in.
- Images: `build/image.sh <name>` regenerates `build/versions.env` from
  `manifests/toolchain.manifest` and then passes every `*_VERSION` from it
  as `--build-arg`, so an `ARG` default in a Buildfile only applies when the
  variable is absent from the manifest.
- `build/rules.build` is the include-path rule file; see the comments there.
