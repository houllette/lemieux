# Customizing Lemieux

You can change how Lemieux works at several levels: saved `lmx` settings,
instructions the model reads, tools it can call, policy the host enforces,
and strategies written in Elixir. Start at the level that matches your
change. The same extension contracts work in `lmx` and in an application that
embeds Lemieux.

## Choose where your change belongs

| You want to change… | Start with | Continue with |
| --- | --- | --- |
| Model, reasoning effort, limits or CLI defaults | [Personal configuration](configuration.md#personal-configuration) | [CLI options](cli.md#common-options) |
| Repository conventions or reusable instructions | [Workspace instructions and skills](configuration.md#workspace-discovery) | [System prompts](configuration.md#system-prompts) |
| Whether an action is allowed | [Hooks and approval policy](hooks.md) | [Execution authority](tool-contracts.md#host-profiles) |
| A capability the model can call | [Your first extension](first-extension.md) | [Writing a tool](tool-contracts.md#writing-a-tool-the-shortest-path) |
| Tools provided by another program or service | [MCP](mcp.md) | [MCP configuration](configuration.md#mcp-servers) |
| Prompt, tools and strategies as one reusable package | [Your first extension](first-extension.md) | [Harness composition](extensions.md#the-harness) |
| Retained context or the summary strategy | [Compaction](compaction.md) | `Lemieux.Compaction` |
| Themes, keys, status, layout or slash commands | [Terminal UI customization](terminal-ui.md) | `Lemieux.TUI` |
| A task with several model and deterministic stages (experimental) | [Agent development](agent-extensions.md) | `Lemieux.Agent` |

Instructions tell the model how to work. Tools grant capabilities. Hooks and
execution environments enforce policy whatever the model says. A request to
avoid shell commands belongs in instructions if it is a preference; a
requirement that shell commands cannot run belongs in the host's tool
catalog, hooks or execution environment.

## Customize lmx with settings and instructions

For defaults you want in every session, save settings in
`~/.lmx/config.json`. For example, this bounds model requests and asks before
tools run:

```json
{
  "version": 1,
  "max_requests": 20,
  "permissions": {"mode": "ask"}
}
```

Flags win over environment variables, which win over the file. See
[Configuration](configuration.md) for the supported keys, and
[resume precedence](configuration.md#resume-precedence) for how they interact
with a resumed session's recorded settings.

For repository conventions, add an `AGENTS.md` to the project (`lmx` also
reads `CLAUDE.md`); `/init` asks the agent to draft one. For a reusable task,
create `.agents/skills/NAME/SKILL.md` with the frontmatter and instructions
shown in [the skill guide](configuration.md#agent-skills-and-legacy-commands).
`lmx` discovers workspace instructions and skills, and `lmx run` uses them
unless it runs bare. Sessions in an embedding application use only the
context their host supplies.

Use `--system` to supply the base prompt yourself; the
[system-prompt reference](configuration.md#system-prompts) explains which
hosts layer workspace context over it and when a headless run is bare.
Instructions and skill bodies are model context. Native extensions and command
hooks run code, and their place in the
[trust model](../SECURITY.md#what-lmx-trusts-by-default) is different.

You can also adjust the terminal without writing Elixir: `theme`, `themes`,
`keys` and `processing` are personal settings. Start with
[adding a theme](terminal-ui.md#adding-a-theme) or
[rebinding keys](terminal-ui.md#rebinding-keys).

## Package behaviour in an extension

An extension implements `Lemieux.Extension`. It receives a `Lemieux.Harness`
and returns one with changed settings. Typical changes add a tool, append a
hook, wrap an existing tool or replace a strategy.

[Your first extension](first-extension.md) runs a complete tool extension
with a scripted provider, so you can learn the lifecycle without an API key.
It also shows how to select the extension in an embedding application and
install it into `lmx`. A small extension can be a single script that
`lmx extension new NAME` writes; a larger one is a Mix project.
[Installation](extensions.md#installing-an-extension-into-lmx) covers the
manifest and the loader's rules.

Extensions compose **left to right**. Appending keeps what is already there;
replacing a field replaces earlier choices. Session options given beside
`harness:` win over harness fields. Provider, model, store, working directory
and supervisor stay host inputs. An extension's initialization can validate
its configuration; `apply/2` is pure, and the host owns supervised services
and their lifetimes.

For settings that are entirely data, `Lemieux.Extension.Profile` is a
validated JSON profile that selects supported options and known tools. A
profile does not load modules or supply credentials. A plugin bundle, from
the Claude Code ecosystem, packages skills, commands, hooks or MCP servers for
the CLI; it is a separate format from a native extension. See
[profiles](extensions.md#a-profile-is-a-data-only-extension) and
[plugins](configuration.md#claude-compatible-plugins-and-marketplaces).

## Customize an embedding application

Start with [First embedded agent](first-embedded-agent.md), then use the
[embedding reference](embedding.md) to pass session options directly or to
assemble a harness. You do not need an extension for an option only one host
uses.

| Host concern | Public API or guide |
| --- | --- |
| Approve, deny or observe tools and requests | `Lemieux.Hooks` and [Hooks](hooks.md) |
| Choose where files and commands run | `Lemieux.Environment` and [Tools](embedding.md#tools) |
| Store and resume transcripts | `Lemieux.Store` and [Persistence](embedding.md#persistence) |
| Change user-facing messages or progress checks | `Lemieux.Messages` and `Lemieux.Session.Guard` |
| Replace context compaction | `Lemieux.Compaction` and [Long conversations](embedding.md#long-conversations) |
| Attach a terminal interface | `Lemieux.TUI` and [Hosting the terminal UI](embedding.md#hosting-the-terminal-ui-elsewhere) |
| Observe sessions and test the host | [Telemetry](telemetry.md) and [Testing your host](embedding.md#testing-your-host) |

The [extension recipes](extensions.md#extension-recipes) show how to deny a
call, wrap a tool, change a message or depend on a supervised service.

## Experimental: measuring and tuning

**Experimental.** These tools may change in any 0.x release. Once an
implementation works, [agent development and tuning](agent-extensions.md)
compares and confirms variants of it, and [evaluation gates](evaluations.md)
describe qualification. Every module behind them (under `Lemieux.Agent`,
`Lemieux.Benchmark`, `Lemieux.Learning`, `Lemieux.Feedback`,
`Lemieux.Reflection`, `Lemieux.Evidence`, `Lemieux.Experiment` and
`Lemieux.Asset`) opens its documentation with **Experimental.**, and the
`mix lemieux.*` tasks are marked the same way.
