# Hello extension

- **What it shows:** a complete first extension: one deterministic tool
  (`word_count`), configuration from keyword options or the manifest, and a
  bundle `lmx` can load.
- **Runs offline?** Yes. `mix test` runs a whole session against a scripted
  model, and `lmx explain` makes no model call.
- **Needs:** nothing beyond this checkout. Chatting with the extension needs
  whichever model you normally use with `lmx`.

Follow [Your first extension](../../../docs/first-extension.md) for the
walkthrough.

```sh
# From the Lemieux root, use this checkout:
export LEMIEUX_EXTENSION_BASE="$PWD"
cd examples/extensions/hello
mise exec -- mix deps.get
mise exec -- mix test
mise exec -- mix lmx.extension.build --name hello
cd ../../..
mise exec -- mix lmx explain --extension hello --no-project-mcp --no-delegate
```

`mise exec -- mix lmx` is the source checkout's `lmx`; with an installed `lmx`,
run `lmx explain --extension hello --no-project-mcp --no-delegate` instead. The
build writes the bundle to `~/.lmx/extensions/hello`, and `explain` lists
`word_count` among the tools.

Outside this checkout, the project depends on `lemieux` from Hex. A bundle
built against it (or against a checkout of the release tag your `lmx` came
from, with `LEMIEUX_EXTENSION_BASE` set to it) records the extension API, and
then needs only the same API and OTP major version and an Elixir no newer than
the one `lmx` runs. `lmx explain` prints its Lemieux, Elixir and OTP versions,
and the loader names both sides when they do not fit. Code loading is trusted
and shared within the VM. Dependencies and the library start no Lemieux
runtime on their own.

The example code is licensed under Apache-2.0, like the rest of Lemieux; see
[the examples index](../../README.md#license).
