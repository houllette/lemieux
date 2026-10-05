# Getting help

Lemieux has one maintainer. Help is best-effort, and there is no paid support.
A small reproduction gets an answer faster than anything else.

| You want to | Go here |
| --- | --- |
| Ask how to do something, or whether a behaviour is expected | [Discussions → Q&A](https://github.com/houllette/lemieux/discussions/categories/q-a) |
| Talk through an idea before it becomes a feature request | [Discussions → Ideas](https://github.com/houllette/lemieux/discussions/categories/ideas) |
| Report a bug you can reproduce | [Bug report](https://github.com/houllette/lemieux/issues/new?template=bug.yml) |
| Propose a feature | [Feature proposal](https://github.com/houllette/lemieux/issues/new?template=feature.yml) |
| Report a security vulnerability | **Never in public.** Use [private vulnerability reporting](https://github.com/houllette/lemieux/security/advisories/new); [SECURITY.md](../SECURITY.md) explains what to send |
| Report a Code of Conduct problem | Follow [CODE_OF_CONDUCT.md](../CODE_OF_CONDUCT.md) |

## Before you ask

1. Search the [documentation](https://hexdocs.pm/lemieux), in particular
   [Troubleshooting](../docs/troubleshooting.md) and
   [First session with lmx](../docs/getting-started.md), and search existing
   [issues](https://github.com/houllette/lemieux/issues) and
   [discussions](https://github.com/houllette/lemieux/discussions).
2. Run `lmx explain` in the directory where the problem happens, with the same
   flags. From a source checkout, run `mise exec -- mix lmx explain` instead.
   It sends no model request and prints a JSON report: the Lemieux, Elixir and
   Erlang/OTP versions, the model `lmx` would use and what chose it, whether
   each needed key is present (never its value), the settings in effect, the
   tools and extensions, and where the state directory and log file are.

## What to include

- **Version:** the output of `lmx --version`. From a source checkout, add
  `git rev-parse --short HEAD`. If you embed the library, give the `lemieux`
  version from your `mix.lock`.
- **Platform:** operating system and CPU, the terminal app (and tmux or
  screen, if you use one), and how you installed `lmx`.
- **Model:** the provider and model, as `provider:model`. Never the key.
- **What happened:** the commands or code you ran, what you expected, and what
  happened instead, with the exact error text.
- **`lmx explain` output, redacted.** It never prints key values, but it does
  name local paths, MCP servers and extensions. Remove anything you would not
  publish.
- **Log lines, if they help.** `lmx` writes its log to the `log_file` that
  `lmx explain` reports. Paste only the relevant lines: the log can record
  request details.

Never paste API keys, OAuth tokens, a `.env` file, your `~/.lmx/config.json`,
or a session transcript (`~/.lmx/sessions/*.jsonl`). Transcripts and logs can
contain source code and secrets that a tool happened to read.

## Is it Lemieux or the provider?

Lemieux sends every model request through
[ReqLLM](https://hex.pm/packages/req_llm). A provider rejecting a request, a
model missing from the catalog, or a change in a provider's API often belongs
upstream, in [ReqLLM's issues](https://github.com/agentjido/req_llm/issues).
If you are not sure, report it here: the maintainer will point you upstream,
or re-file it there.

## What to expect

- **Lemieux is pre-1.0.** A minor release may contain breaking changes. Each
  one is listed in the [changelog](../CHANGELOG.md) with a migration note, and
  the [support policy](../docs/support.md) says which surfaces are maintained.
- **Experimental areas get less help.** These may change in any 0.x release:
  the harness-learning, feedback, benchmarking and evaluation tools (modules
  whose documentation opens with **Experimental.**, `lmx feedback`,
  `lmx corpus` and `lmx harness`, and the `mix lemieux.*` tasks), the Windows
  build, and the computer-use example.
- **Answers are best-effort.** Security reports come first.
