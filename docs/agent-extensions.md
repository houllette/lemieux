# Build and tune an agent extension

**Experimental.** May change in any 0.x release.

For a first tool or harness customization, start with [Your first extension](first-extension.md).
This is the optional whole-task development and evaluation lane.

An **extension** is code that shapes the harness a session starts from: a
module implementing `Lemieux.Extension`, whose `apply/2` receives a
`Lemieux.Harness` and returns it changed. [Extensions](extensions.md) is that
contract, the worked example, and the extensions `lmx` itself is assembled
from. This guide is about one lane for producing them: an ordinary **Mix
project**, declared by `lemieux-extension.json`, that specializes the harness
with Elixir preparation, bounded model sessions, tools, instructions and
validation, and can be tuned, frozen, confirmed and exported. Its portable
form, `Lemieux.Extension.Profile`, is a data-only extension — a JSON document
whose `apply/2` sets the prompt, catalog, budgets and generation settings.
A `Lemieux.Agent` is not an extension: it is a runnable that owns a whole
task, and this lane produces those too. **Plugins** remain the separate
ecosystem format for skills and command bundles. Neither installs the other.

Tune the harness for a task, then use the same implementation in a host:

```text
define → cases → compare → inspect and refine → freeze → fresh confirmation
                   ↑             |                         ↓
                   +-------------+                export → host use
```

This tunes code and configuration, not model weights. Hosts retain credentials,
routing, policy, storage and isolation. Adding Lemieux as a dependency starts no
Lemieux processes. Independent confirmation is required before a development
result becomes a qualified export.

## Build in the ordinary TUI

Open `lmx` (from a source checkout, `mise exec -- mix lmx`) and enter
`/create-extension Describe the behavior you want`. The bundled skill guides
the ordinary read, write, edit and bash tools through the extension contract,
implementation, tests and optional CLI bundle. Use `/evaluate-extension` only
when comparing model behavior matters. Neither skill changes your model or
budget; an explicit dollar cap still stops an Ixway route whose future cost
cannot be estimated. A project or personal skill with the same name can
replace the bundled instructions.

## Optional guided builder

```sh
lmx --build-ext
lmx run "Create an extension that reviews API compatibility" --build-ext
# From a source checkout:
mise exec -- mix lmx --build-ext
```

The first-party builder implements the same Agent contract as external extensions.
It asks about the task, representative inputs, acceptance criteria, tools, budget
and model candidates. Interactive hosts supply `ask_user`; headless runs report
missing decisions in their answer. `BUILDING.md` preserves decisions and evidence
between sessions and is included in the generated export manifest.
It is retained for the full scaffold and comparison workflow. Its default
$5 authoring cap requires a priced request estimate; Ixway returns no estimate
before routing, so use the normal TUI for creation or explicitly select
`--build-ext --quota` for an authorized quota session.

Its `extension_workflow` tool provides a workflow guide, configured model
inventory, selection validation, deterministic shortlist saving, comparison planning
and a Mix scaffold.
The ordinary coding tools author domain logic and graders. The scaffold requires
a local environment. Its starter grader deliberately fails until real acceptance
criteria are implemented; graders live outside copied task workspaces.

`--model provider:id` selects the builder's authoring model. Models to compare
for the extension being built are a separate choice. The welcome message shows
the actual authoring model and effort. If an implicit model is unavailable in
the configured catalog, startup chooses a listed fallback; this is not ranking.

The provisional `zai_coding_plan:glm-5.3` recipe uses low effort, 4,096 output
tokens and 30 turns. Other models use provider-default effort. Hosts can override
it with `Builder.profile(model, reasoning_effort: "default")`. This recipe was
selected on exposed development cases; it is not independently qualified.

The guide lists built-in profile tools. Extensions can add native tools through
an explicit compiled registry. For example, `fetch` is not a built-in tool: implement
and register it before offering it as an available choice. `scaffold` requires
`directory`, `name` and `profile_json`, and reports the specific failed validation.
A generated project depends on the Lemieux release that generated it, from Hex
(for example `{:lemieux, "~> 0.8.0"}`), and needs Elixir 1.19 or later.
`LEMIEUX_EXTENSION_BASE`, set to the absolute path of a checkout, replaces that
with a path dependency for local development.

Before quoting a quota plan, call `extension_workflow` with `action="plan_models"`,
`selection_json`, `case_count`, `repetitions`, `max_attempts` and
`max_requests_per_attempt`. The result includes the expanded candidate count,
planned attempts, maximum direct requests and `fits_budget`. `max_attempts` caps
**the whole comparison**, not retries per case. These settings do not alter the
builder session's own limits; launch with `--build-ext --quota` for quota authoring.

Use `/reflect` after a difficult builder session to identify possible workflow,
prompt or benchmark improvements. It uses the [same reflection workflow](reflection.md)
available in base Lemieux. Profile-backed sessions record a profile digest and
designation for that review. Recommendations are not applied automatically.

## Native tools, pipelines and dependencies

Extensions are native Elixir packages, not just prompt presets. Prefer ordinary
modules for repeatable preparation, validation, parsing, routing and policy; use
model calls where judgment helps. A deterministic function can be used directly
by a pipeline and exposed to the model through a `Lemieux.Tool` wrapper.

The generated agent has `tool_registry/0`, `configure/2` and `cli/2`:

```elixir
def tool_registry, do: [MyExtension.Tools.Nmap, MyExtension.Tools.CheckPolicy]

def configure(profile, opts) do
  Lemieux.Extension.Profile.configure(
    profile,
    Keyword.put(opts, :tool_registry, tool_registry())
  )
end
```

The profile selects names such as `"nmap_scan"`; the registry supplies compiled
implementations. `Profile.read/2`, `validate/2`, `session_options/3` and
`configure/2` accept `tool_registry: [...]`. Missing names, duplicate definitions
and built-in name collisions fail before a model request. JSON does not load
source or turn module strings into atoms. Configured tool structs are supported;
reconstruct their runtime state in the host when resuming.

Generated workbenches call the extension's `configure/2`, keeping the same tools
in evaluation. For interactive or headless use from its compiled Mix project:

```sh
mix run -e 'MyExtension.cli()'
mix run -e 'MyExtension.cli(["run", "TASK"])'
```

These delegate to `Lemieux.Extension.CLI.run(profile, argv, tool_registry: tools)`
and the ordinary TUI/headless hosts. Generated projects include the existing
optional `ex_ratatui` dependency for TUI use; a consuming host must opt into it too
if it wants a terminal interface. Headless hosts do not need it. A prebuilt `lmx --extension-profile`
process cannot load modules merely because their names appear in JSON: install
the Mix extension in the host that runs it. Model-generated tool calls retain
normal hooks, supervision, environment execution, result bounds and transcripts.
A tool wrapping an external program should use that host environment instead of
silently running on a different machine. Validate arguments and expose terminal
status; an external program remains a documented runtime prerequisite.

See the [security example](https://github.com/houllette/lemieux/blob/main/examples/extensions/security/README.md): it packages
an Nmap wrapper, pure command preparation and port policy, model-callable tools,
and an ordinary Agent. Its deterministic functions can also be called headlessly
without a model. It also ships a host hook, `SecurityExample.Scope`, that lets
`nmap_scan` touch only the targets listed in
`config :security_example, scan_targets: [...]`: single IPv4 addresses, only
`127.0.0.1` in the example's own configuration, and nothing at all when none
are configured. The denial is the tool result the model reads. Both of its
entry points apply the hook after the host's own hooks, so passing hooks never
widens the scope. For an agent that always runs several stages, implement `run/2`
with ordinary functions/`with` and bounded `Agent.Session` calls; the
[verifier example](https://github.com/houllette/lemieux/blob/main/examples/extensions/verifier/README.md) is one, running a
session, the repository's own check, and one bounded retry. Such pipeline
agents own their interactive adapter and account for all stages and budgets.

Hex dependencies belong in the extension's `mix.exs`. Resolve and lock them, add
`mix.lock` to `lemieux-extension.json`, and list every tool/pipeline module, test
and required `priv` asset. Ordinary Mix consumers resolve those dependencies;
exports never vendor `deps` or `_build`. Export copies only files under `lib/`,
`priv/`, `test/` and `bench/`, plus a root `mix.exs`, `mix.lock`,
`.formatter.exs`, `README.md`, `BUILDING.md`, `LICENSE` and `LICENSE.md`, so
an extension's `config/` stays behind: a consuming host supplies that
configuration itself (the security example's `:scan_targets`, for one).

Freeze captures declared source and the selected compiled dependency runtime,
not a reproducible build from a lockfile. Dependencies requiring application
startup/configuration, native executables or custom compilers need those
prerequisites supplied explicitly by the consumer; the existing confirmation
lane does not invent them.

Test deterministic code directly, then benchmark the full agent using its native
tools. Freeze source, profile and dependencies together before confirmation so
an improved model score cannot conceal a changed tool implementation.

## One profile across interfaces

`Lemieux.Extension.Profile` records the model, instructions, tools, generation
settings and bounds for a session-based extension. Generated agents expose
`profile/0`, implement `configure/1`, and run through `Lemieux.Agent.Session`.
The same profile can open the CLI:

```sh
lmx --extension-profile priv/profile.json
lmx run "TASK" --extension-profile priv/profile.json
```

Interactive hosts add the human-question channel. Explicit profiles do not
silently acquire workspace instructions or conflicting model/tool flags.
Profile flags cannot be combined with `--resume`; ordinary resume restores
conversation configuration, while the host resupplies dynamic tools and policy.
Runtime changes to tuning do not inherit an earlier qualification.

`options.tool_descriptions` is the one optional profile key. It maps a tool
name the profile lists — built-in or registry — to the description the model
is shown for it, and the session wraps that tool in `Lemieux.Tool.Override`
so execution is untouched. Tool interface text is the surface where harness
edits pay and transfer between models, which is why it is tunable from a
profile at all; the system prompt is not a substitute. A description for a
tool the profile does not list, for the host workflow tool, or an empty one
fails validation. Profiles without the key stay valid byte for byte, and
adding one changes the profile digest like any other tuning change. It is
also one of the two surfaces the discovery proposer mutates, beside
`options.system`; see the
[search guide](harness-learning.md#search-proposer-and-standalone-campaigns).
`Profile.retarget/3` points the same profile at another model and changes
only its budget shape, which is how model portfolios and the confirmation
lane run one candidate on a model the search did not use.

An arbitrary multi-stage Elixir agent owns its conversational adapter: loading
a session profile does not execute arbitrary installed modules. Library hosts
execute the whole composition through `Lemieux.Agent.run/3`:

```elixir
@behaviour Lemieux.Agent

@impl true
def run(input, opts) do
  with {:ok, prepared} <- prepare(input),
       {:ok, observation} <- Lemieux.Agent.Session.run(prepared, opts),
       :ok <- validate(observation) do
    {:ok, observation}
  end
end
```

Input contains `prompt`, `cwd` and `timeout_ms`. A successful observation has
`"status" => "completed"` and a string `"answer"`; usage and evidence must cover
the whole composition. Multi-session agents own cumulative deadlines, usage and
cleanup. The session runner accepts a host provider, supervisor and store; its
convenience runtime is shared independently of short-lived callers. Where
`Lemieux.start_session/1` would raise for a malformed option, it returns a
result instead: `{:error, {:provider, :invalid}}` (or `:store`) for a value
that is not a `{module, state}` pair, and `{:error, {key, :required}}` for a
provider or model left out, or a provider, store or model given as `nil`.

## Cases and comparisons

The developer owns representative cases and mechanical acceptance criteria.
The [review example](https://github.com/houllette/lemieux/blob/main/examples/extensions/review/README.md) demonstrates
selection, a bounded session and finding validation. The
[builder example](https://github.com/houllette/lemieux/blob/main/examples/extensions/builder/README.md) exercises scaffolding,
clarification and refinement. The
[research example](https://github.com/houllette/lemieux/blob/main/examples/extensions/research/README.md) composes web
search and page fetch into a cited answer whose citations are checked against
what was fetched. These exposed fixtures demonstrate integration,
not general review, builder or research quality.

Evaluate the same entry point a consuming host uses:

```elixir
runtime = Lemieux.Benchmark.Runtime.new("reviewer", Lemieux.Benchmark.Runtime.Agent,
  agent: MyExtension.Reviewer,
  agent_options: options
)
Lemieux.Benchmark.run_file("bench/manifest.json", [runtime], repetitions: 2)
```

Use `agent: Lemieux.Agent.Session` for an ordinary-session control through the
same adapter. It requires normal completion as well as a passing artifact.
The historical `Benchmark.Runtime.Native` retains artifact-oriented semantics;
mixing these acceptance rules would confound a comparison. Agents receive no
grader or private benchmark metadata, but API separation is not OS isolation.

A trusted `bench/workbench.exs` returns:

```elixir
[
  suite: "bench/manifest.json",
  agents: [{"baseline", MyExtension.Reviewer, fn -> host_options() end}],
  execution: :live,
  workbench_dir: "tmp/extension-workbench",
  benchmark_options: [repetitions: 2, cost_cap_usd: 2.00,
                      max_cost_per_attempt_usd: 0.25]
]
```

Use a zero-arity options factory for stateful providers so each attempt starts
fresh. Configuration files execute trusted Elixir, even when only displaying a
plan. The workbench must live outside task workspaces. `:execution` defaults
to `:live`: the workbench asks for confirmation before a live run, and
`mix lemieux.extension.eval` refuses one without `--allow-live`. A
configuration that declares `execution: :scripted` runs offline in both
without the flag.

```sh
mix lemieux.extension.workbench bench/workbench.exs
mix lemieux.extension.eval bench/workbench.exs --allow-live
```

The workbench is a line-oriented local interface:

| Command | Purpose |
| --- | --- |
| `cases`, `variants` | Inspect cases and requested settings |
| `case`, `variant` | Define a case or named tuning variant |
| `select` | Choose cases and ordered variants |
| `run` | Plan a comparison; a live project then asks you to type `run-live` at its prompt before dispatching |
| `reports`, `inspect` | Inspect outcomes, errors, graders and resources |
| `help`, `quit` | Show commands or exit |

Case/variant edits persist in `project.json`; runs save `plan.json` and
`report.json`. The library exposes these operations through `Extension.Workbench`.
Requested overrides are not proof that custom code used them: inspect effective
requests. Plans record development choices but do not freeze executable source.
Unknown counters remain unknown, and interrupted work remains incomplete.

## Choosing providers, models and effort

Use `Extension.ModelSearch.inventory/2` with the actual host provider connection.
Scoped keys determine configured providers. A catalog entry does not prove account
entitlement or current reachability; hosts may supply `:available_models` from a
connection-specific listing, and actual benchmark calls test usability.

Select at most 32 explicit model/effort combinations in `bench/models.json`:

```json
[
  {"model": "provider:model-a", "efforts": ["default", "high"]},
  {"model": "provider:model-b", "efforts": ["default"]}
]
```

Explicit efforts must be advertised. `default` clears inherited effort; it does
not imply equal reasoning across models. The builder's `save_models` validates
before writing through the host environment, preserving this grouped schema.
`select_models` only inspects choices; its expanded records are not search files.

```sh
mix lemieux.extension.compare bench/workbench.exs bench/models.json
mix lemieux.extension.compare bench/workbench.exs bench/models.json --allow-live
```

Set `:search_provider` in the trusted config to the same connection agents use.
The first configured agent is the base. Planning invokes no model or options
factory. Live execution uses paired workspaces and the same resource bounds.
No command selects a winner automatically. Compare quality and regressions first,
then errors, latency, tokens and dollars across all attempts. Keep model search
separate from prompt/tool changes where possible, and confirm selected settings
on fresh cases before making a qualification claim.

## Budgets and subscriptions

The builder defaults to a $5 session cost cap and 30 turns. For subscriptions:

```sh
lmx --build-ext --quota --model zai_coding_plan:glm-5.3
```

Z.AI Coding Plan is the separate `zai_coding_plan` provider. Quota mode removes
the dollar cap and bounds direct requests: 12 for this GLM-5.3 recipe, 30 for
other builder models. `Profile.quota(profile, maximum_requests)` supports custom
limits. Request limits include compaction and restored requests. These are local
bounds, not the account's remaining quota. Unknown dollar usage is not zero.

Quota workbenches set `usage_mode: :quota`, `max_attempts` and
`max_requests_per_attempt` in `benchmark_options`. Metered runs require both
a total cost cap and a per-attempt reservation. Stricter session caps are retained.
Live workbench calls require `allow_live: true` / `--allow-live`; `--run` alone
cannot authorize live dispatch. Prior user authorization need not be requested again.

These bounds do not cover separate programs launched by `bash` or arbitrary
multi-session code. A host needing a campaign-wide enforced ledger owns that
execution boundary. Failed headless sessions return a failure status, including
request exhaustion, unknown-price refusal and truncated output.

For quota confirmation, `extension_policy` contains `usage_mode: "quota"`,
`maximum_requests`, `max_requests_per_attempt`, `repetitions`,
`maximum_mean_latency_ms` and `unknown_cost: "allow"`. The experiment `budget`
has matching usage mode and total request allowance. Reserve both arms × cases ×
repetitions × per-attempt requests. Missing request counts prevent qualification.

## Export and installation

Declare source explicitly in `lemieux-extension.json`:

```json
{
  "schema_version": 1,
  "module": "MyExtension.Reviewer",
  "files": ["mix.exs", "lib/my_extension/reviewer.ex", "README.md"]
}
```

`mix lemieux.extension.export SOURCE NEW_DESTINATION` copies the selected bytes
and writes an integrity receipt. `Extension.verify/1` checks the exact file set;
symlinks, traversal and unsupported roots are rejected. Export neither publishes
nor installs dependencies. Authors own licenses and the contents of selected files.

The scaffold depends on the Hex release that generated it (`~> 0.8.0` admits
0.8.x and refuses 0.9.0), with `LEMIEUX_EXTENSION_BASE` as an optional local
override. When you upgrade Lemieux, raise that requirement deliberately and
rerun the extension tests before distributing a new bundle. A local consumer
can use `{:my_extension, path: "../exported-extension"}` and call its Agent
module.

Ordinary exports are **unassessed**, even after a green development comparison.
For a performance claim, [freeze and independently confirm](agent-extensions.md#confirmation-and-qualified-export)
the exact source, profile and runtime first. Confirmation supports trusted ordinary
Elixir source; custom compilers and hostile code need a host-specific lane.

The local workflow needs no hosted service: neither Ixway nor any other host.
Hosted multi-user campaigns, isolation, approval and activation remain host
responsibilities. Autonomous refinement of a session profile is the discovery
lane: it searches the same `Lemieux.Extension.Profile` shape over
`options.system` and `options.tool_descriptions`, and a cycle can run it
unattended; see
[Search, proposer and standalone campaigns](harness-learning.md#search-proposer-and-standalone-campaigns)
and [Using self-improvement regularly](harness-learning.md#using-self-improvement-regularly).
The builder is a guided authoring interface and is not itself searched.
Broad empirical qualification of its recipe remains
[roadmap item V1](roadmap.md#acceptance-and-experiments-still-to-run).

## Confirmation and qualified export

Start with the [extension guide](agent-extensions.md). Use ordinary unassessed
export when you need distribution without a performance qualification claim.


The confirmation workflow provides `Lemieux.Learning.Extension.Build`, `Lemieux.Learning.Extension.Confirmation`, and
three explicit CLI steps. The workbench remains development-only; confirmation
is a separate, private evaluation directory after one candidate is selected.

1. Implement the optional `c:Lemieux.Agent.configure/1` callback. It receives a
   JSON profile and returns `{:ok, executable_options, effective_profile}`.
   The returned effective profile must exactly match the frozen profile. Resolve
   all model, system, tools, parameters and behavioral defaults there. Fetch
   credentials only in the child environment. The same callback can be used by
   an installing host before calling `Lemieux.Agent.run/3`.
2. Freeze control and candidate separately with `Build.freeze/4`, or
   `mix lemieux.extension.freeze CONFIG.exs NEW_DIRECTORY`. The trusted config
   returns `source:`, `profile:` and optional `runtime_paths:` / `runtime_assets:`.
   Retain each printed SHA-256 outside the frozen directory.
3. Construct a `Lemieux.Benchmark.Corpus` with full development/validation and
   holdout membership and exposure history. Use `Workbench.expose_corpus/2` to
   include current and saved-run workbench cases. Include ancestor/derived
   exposure from other tools in the same ledger. Unknown case IDs fail rather
   than silently dropping history. Every case needs metadata `cluster_id`;
   clusters represent independent tasks, not repetitions or related mutations.
4. Preregister using `mix lemieux.extension.confirm prepare CONFIG.exs DIRECTORY`.
   That trusted config returns `control:` and `candidate:` opened Build structs,
   `corpus:`, `experiment:` and `evaluator_root:`. It may also provide an existing
   `discovery_candidate:` and extra `evaluator_runtime:` executable names/paths.
5. Run once with `mix lemieux.extension.confirm run DIRECTORY EXPECTED_SHA256`.
   Live profiles additionally require `--allow-live`. Inspect private
   `report.json` and `result.json`, then export a passing result with
   `mix lemieux.extension.confirm export DIRECTORY EXPECTED_SHA256 NEW_PACKAGE`.
   Install the resulting ordinary Mix project through your host's normal deps.

A frozen profile has exactly four fields:

```elixir
%{
  "execution" => "live", # or "scripted", a trusted host declaration
  "model" => "provider:model",
  "tools" => ["MyExtension.ReadOnlyTool"],
  "options" => %{
    "system" => "The complete chosen instructions",
    "max_turns" => 4,
    "temperature" => 0,
    "max_cost_usd" => 0.25
  }
}
```

Profiles are explicit non-secret data. Common credential fields are rejected;
authors remain responsible for strings and assets they choose to include.
Metered live profiles require a positive `options.max_cost_usd`. Quota profiles
use `Profile.quota/2` and explicit request allowances instead; see
[quota configuration](agent-extensions.md#budgets-and-subscriptions). The consumer tightens
the ordinary session cap to that amount; confirmation also requires it to fit
the per-attempt reservation. Multi-session extensions still own cumulative
bounds and inclusive usage across all their stages.

An example `experiment:` map (choose thresholds before seeing outcomes):

```elixir
%{
  "hypothesis" => "The selected extension improves independent task pass rates",
  "metric" => %{"kind" => "continuous", "minimum_effect" => 0.10},
  "stopping_rule" => %{"minimum_pairs" => 20, "confidence" => 0.95},
  "budget" => %{"maximum_cost_usd" => 20.0},
  "extension_policy" => %{
    "repetitions" => 2,
    "maximum_cost_usd" => 20.0,
    "max_cost_per_attempt_usd" => 0.25,
    "maximum_mean_latency_ms" => 60_000,
    "maximum_total_tokens" => 500_000,
    "unknown_cost" => "reject"
  }
}
```

The stopping rule may instead be anytime-valid:
`%{"kind" => "e_process", "alpha" => 0.05, "minimum_pairs" => 20,
"range" => [-1, 1]}`, optionally with a fixed `"lambda"` (positive, at most
`1 / (hi - lo)`). The decision then runs paired Hoeffding e-processes over
the holdout differences and may commit or reject the moment either reaches
`1 / alpha`, or keep sampling, without inflating the false-commit rate that a
"keep it if it scored higher" loop pays for on every peek. `range` bounds the
paired differences and is declared, not inferred; a binary metric must declare
`[-1, 1]`, and evidence outside the range is refused rather than clamped.
Without a declared `lambda` the bet is `min(4δ / R², 1 / R)`, with `δ` the
declared minimum effect and `R` the width of `range`, or `1 / R` when `δ`
is not positive.

The discovery lane's confirmation, `mix lemieux.discovery.confirm`, reuses
this same `Experiment.Plan`, `Experiment.Decision` and e-process rule for a
searched profile candidate. Its `--model` flag runs both arms on a target
model as the transfer check, and `--legacy-rule` selects the fixed-n
interval instead; see
[Confirming a candidate on a target model](harness-learning.md#confirming-a-candidate-on-a-target-model).

This uses the existing `Experiment.Plan` and `Experiment.Decision` contracts.
Related cases and repetitions become one cluster mean before the paired
interval is calculated; they cannot inflate the independent sample. There must
be at least two independent clusters and at least the declared minimum. The
existing normal approximation is a modest first statistical lane, not a claim
that tiny samples establish generalization. A case marked `critical: true` in
metadata cannot regress; reported safety violations block qualification.
This trusted local lane does not attest OS containment or absence of unreported
safety problems. Each workspace copy is initialized as its own Git
repository so Git commands the agent runs stop there; a copy under a
directory inside another repository would otherwise let `git commit` reach
that repository.

The evaluator directory contains the frozen graders. Each case's
`grader.command[0]` is relative to that directory, for example
`["grade.sh", "{answer}"]`. It becomes an absolute path only in the private
host manifest. Cases passed to agents contain only prompt, copied workspace
and timeout. Shebang interpreters are fingerprinted and checked again before
execution/export; list additional external programs in `evaluator_runtime:`.
Package the evaluator's scripts/assets in that directory. OS libraries and
ambient environment remain host-owned; this lane is not a hermetic sandbox.

Missing, duplicated, failed or interrupted attempts cannot qualify. Dollar
reservations are never reported as measured spend. `unknown_cost: "allow"`
permits a quality-only result with unknown dollars explicitly retained; it
cannot establish cost efficiency. Token limits require complete input/output
accounting. Latency includes the fresh consumer's startup and compilation.

The exclusive `exposure.json` marker is written before the first attempt. Keep
it even after interruption and import its source-case closure into the host
ledger (`Confirmation.exposure/1` reads it). A directory is single-use; deleting
it and rerunning the same cases does not make them independent. The library
cannot recover history that an operator discards or detect semantic near-duplicates
without truthful cluster assignments.

Freeze preserves declared source/assets and captures exact dependency BEAM bytes
and runtime assets. Each attempt compiles frozen `lib/**/*.ex` in a fresh BEAM.
The source package preserves `mix.exs` and declared `mix.lock`; this is **not** a
reproducible dependency build from lock files. Elixir/OTP/architecture must match.
Custom Mix compilers, implicit application configuration, platform changes and
untrusted extension code need a host-specific build/isolation lane. `configure/1`
is a trusted contract: matching its effective profile cannot prove that arbitrary
Elixir obeys its declared settings. The review example intentionally supports
only a scripted profile to demonstrate this path.

Confirmed export revalidates build, evaluator, exposure, exact attempt set and
thresholds. It copies only the frozen candidate's declared source. The ordinary
package receipt remains `unassessed`; the separate `NEW_PACKAGE.confirmation.json`
records the scoped confirmation, build/profile and evidence hashes without
hidden case IDs, graders or transcripts. `Confirmation.verify_export/3` checks
that receipt against the pinned private experiment. A checksum is not a signature;
retain trusted digests and private evidence separately. A new host must preserve
the qualified runtime/profile and repeat its smoke/regression checks; installing
source with different dependencies does not inherit the old qualification.

The tests demonstrate provenance, budgets, exposure policy and a separate Mix
consumer. **No real fresh-task efficacy claim is made by those scripted tests.**
Automatic refinement of a session profile is the
[discovery lane](harness-learning.md#search-proposer-and-standalone-campaigns);
hosted activation remains future work in the roadmap's
[hosted integration section](roadmap.md#hosted-integration-still-to-complete).
