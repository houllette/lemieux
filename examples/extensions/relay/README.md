# Model route example

- **What it shows:** a one-file extension that registers a **model route**:
  an OpenAI-compatible server you run (vLLM, LM Studio, llama.cpp's server,
  LiteLLM, a proxy of your own), under its own provider name `relay`, with
  the models you list.
- **Runs offline?** Yes. Loading it and `lmx explain` make no model call, and
  the root test suite runs it against a local stand-in server
  (`test/lemieux/relay_example_test.exs`).
- **Needs:** `lmx` or this source checkout, a server speaking
  `/v1/chat/completions`, and `RELAY_API_KEY` in the environment.

`relay.exs` defines the extension and the route. `extension.json` names the
module, the script, the Lemieux it was written for and the route's options:

```json
{"schema_version": 1, "name": "relay", "module": "LemieuxRelayExample",
 "script": "relay.exs", "versions": {"lemieux": "~> 0.8"},
 "options": {"endpoint": "http://localhost:8000", "models": ["qwen3-32b"],
             "default": "qwen3-32b", "context_window": 32768}}
```

The module exports no `apply/2`: it shapes no harness. It exports `routes/1`
(`Lemieux.Extension.Routes`), which `lmx` calls after loading the directory
and whose answer it registers (`Lemieux.CLI.Routes`). From then on `relay:ID`
is a model like any other, served by this route and nothing else.

## Configure it

Copy the directory to `~/.lmx/extensions/relay` so `"extensions": ["relay"]`
and `--extension relay` find it (or load it straight from this checkout with
`--extension-dir`, below). Then point it at your server in
`~/.lmx/config.json`, over the manifest's defaults, and give it the bearer
token the server expects:

```json
{
  "extensions": ["relay"],
  "extension_options": {
    "relay": {
      "endpoint": "http://localhost:8000",
      "models": ["qwen3-32b", "glm-5.3-air"],
      "default": "qwen3-32b",
      "context_window": 32768
    }
  }
}
```

```sh
export RELAY_API_KEY=...   # or RELAY_API_KEY=none for a server that checks none
```

The variable is required even when the server checks no key: a request
with no key would make `req_llm` look for `OPENAI_API_KEY`, and your OpenAI
key must not leave for a server that is not OpenAI. `"api_key_env"` names
another variable. `"context_window"` is what the server gives a model, so a
long session compacts in time. Prices are unknown here, so a session under
`max_cost_usd` refuses the route's requests rather than counting them as
free; bound one with `max_requests` or `max_turns` instead.

## Use it

Loading is explicit: `lmx` never picks up an extension because a repository
contains one. From the repository root:

```sh
RELAY_API_KEY=none lmx explain --extension-dir examples/extensions/relay --model relay:@default
lmx --extension-dir examples/extensions/relay --model relay:qwen3-32b     # the TUI
lmx run --extension-dir examples/extensions/relay --router relay "Summarize this repository"
```

From a source checkout without an installed `lmx`, use `mise exec -- mix lmx`
in place of `lmx`. `explain` reports `relay` under `diagnostics.route`, the
credential as `route_managed`, and `relay:qwen3-32b` as the model that
`relay:@default` resolved to.

- `--model relay:ID` names one of its models; `relay:@default` is the
  configured `"default"`.
- `--router relay` makes it the route for the command: `lmx run` sends
  through it alone, with no direct credential to fall back on; the terminal
  UI keeps the direct providers beside it, and `/provider relay` switches to
  it. `providers.relay.model` and `providers.relay.effort` in the config file
  apply to it as to any provider.
- A model the relay does not serve is refused in a sentence, before a
  session starts; so is a missing `RELAY_API_KEY` or a malformed endpoint.
  Nothing falls back to another provider.

To stop using it, stop selecting it: take `"relay"` out of `"extensions"`
or leave the flag off. A transcript that recorded a `relay:` model then
refuses to resume until the extension is selected again, and says so.

## Write your own

The route is `LemieuxRelayExample.Route`, a `Lemieux.Provider.Route`: the
catalogue (`available_models/2`, `validate_model/3`), the window, the
reasoning-effort menu, and `target/3`, which pins `req_llm`'s OpenAI chat
encoding and sends every request to the configured origin with the
configured key while letting only generation parameters cross from the
session. `ready/1` is where a server that lists its own models would be
asked, once; `default_model/1` is what `relay:@default` resolves to. The key
never enters the route's state: the state names the variable, `target/3`
reads it for each request, and nothing writes it to a transcript. A script
compiled by the running `lmx` cannot derive a quiet `Inspect`, since the
protocols are consolidated before it compiles, so that is the shape a script
route keeps; a compiled bundle may hold a key and derive `Inspect` instead.
`lmx` readies only the start model's route, so a route switched to with
`/provider` must list its models from the state it has — this one keeps its
catalogue there from the start. See
[Adding a model route](../../../docs/extensions.md#adding-a-model-route).
