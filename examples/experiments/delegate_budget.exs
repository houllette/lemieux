# Does a delegated child finish inside the budget the host gives it?
#
#     set -a; . ./.env; set +a
#     LMX_DELEGATE_BUDGET_MODEL=zai_coding_plan:glm-5.3 \
#       mix lemieux.extension.eval examples/experiments/delegate_budget.exs --allow-live
#     LMX_DELEGATE_BUDGET_MODEL=ixway:gpt-5.6-luna \
#       mix lemieux.extension.eval examples/experiments/delegate_budget.exs --allow-live
#
# LMX_DELEGATE_BUDGET_MODEL (provider:model) is required: every attempt is a
# live, billed or quota-consuming call, so nothing picks a provider for you.
#
# The finding this measures (feedback fb_01M2S6FMZKDX7YKSPQ0RCQ5C5V): the model
# writing a child's objective is never told the child's budget.
# `Lemieux.Subagent.Delegate.description/1` says a child is one to three
# foreground, depth-one, read-only investigations and names the definitions; it
# does not say six turns and two minutes. Observed in the TUI: asked about one
# module, the parent briefed the child for purpose, public API, internal
# behavior, dependencies and missing coverage; the child had the answer on turn
# one and spent the rest hunting for tests, then stopped after six turns with an
# empty envelope.
#
# The arms differ in exactly one factor, the child's turn budget. System
# prompt, tools, model, fan-out, timeout and the parent's own limits are
# identical, so a difference in the frontier is the budget and nothing else.
#
# **The parent holds `delegate` and not `read`.** That is the point: with
# `read` it answers the case directly and this measures nothing about
# delegation. `Lemieux.Extension.Profile` has a closed tool vocabulary that
# cannot carry `delegate`, which is why this is an `Lemieux.Agent.Session`
# experiment rather than a profile-pairing campaign — the same reason
# `investigators.exs` gives.

alias Lemieux.CLI.Options
alias Lemieux.CLI.Runtime
alias Lemieux.Subagent.Definition
alias Lemieux.Tools

model =
  System.get_env("LMX_DELEGATE_BUDGET_MODEL") ||
    raise "set LMX_DELEGATE_BUDGET_MODEL=provider:model to choose the model both arms run on"

# An `ixway:` model resolves only through a provider built with the gateway
# connection, so the route has to come from the CLI's own configuration.
# `investigators.exs` takes a direct connection on purpose — it is measuring a
# model and a gateway would confound that — but the defect this experiment is
# about was found on a gateway route, and the child budget is the same factor
# either way.
provider = fn ->
  if String.starts_with?(model, "ixway:") do
    {:ok, options} = Options.parse([])
    Runtime.provider(options)
  else
    Lemieux.Providers.ReqLLM.new(receive_timeout: 120_000)
  end
end

slug = String.replace(model, ~r/[^A-Za-z0-9.-]/, "_")

run =
  System.get_env(
    "LMX_DELEGATE_BUDGET_RUN",
    "#{Date.to_iso8601(Date.utc_today())}-#{slug}"
  )

output_dir = Path.join(["tmp/experiments/delegate-budget", run])

# Quota by default: the route this was found on cannot price a request, and a
# dollar cap there stops a child before it starts. See
# `Lemieux.Subagent.Definition`.
metered? = System.get_env("LMX_DELEGATE_BUDGET_USAGE", "quota") == "metered"

# Above every arm's turn count, so the factor that varies is turns and the
# budget never becomes the binding one. Getting this wrong makes an arm look
# like a turn result when it is really a budget result.
child_budget = if metered?, do: [max_cost_usd: 0.5], else: [max_requests: 150]

scout = fn turns ->
  turn_bound = if turns, do: [max_turns: turns], else: []

  Definition.new(
    [
      id: "repository-scout",
      description: "Inspect the working tree and return source-cited findings",
      system_prompt:
        "Read the repository directly. Cite exact paths and line numbers, report uncertainty, " <>
          "and say what you searched. Do not propose or make writes.",
      model: model,
      tools: [Tools.Read],
      timeout: :timer.minutes(2)
    ] ++ turn_bound ++ child_budget
  )
end

# The product's own prompt, plus the one fact this arm changes. An earlier
# version wrote its own and confounded the fabrication measurement in both
# directions: it dropped the default's "if you could not do something, say so
# plainly ... do not describe work you did not perform", and added "name the
# exact value asked for", which presses for a number whether or not one was
# found. A parent measured under that prompt is not the parent `lmx` runs.
system =
  Lemieux.Prompt.default() <>
    "\n\nYou have no file tools in this session. Delegate the investigation and answer from " <>
    "what the investigators report."

arm = fn turns ->
  fn ->
    [
      provider: provider.(),
      model: model,
      sessions_dir: Path.join(output_dir, "sessions"),
      session_options: [
        # No `read`: the parent must delegate or it cannot answer at all. The
        # host builds the delegate tool and hands it to the session like any
        # other tool. Three children at their full budget is one fan-out; two
        # of those is the tree. Below `3 * child_budget` every delegate call
        # is refused with `:root_request_budget_exhausted` and the arm
        # measures nothing — which is exactly what a run at 96 against a
        # 150-request child did.
        tools: [
          Lemieux.Subagent.Delegate.new([scout.(turns)],
            snapshot: %{"kind" => "working_tree", "version" => 1},
            max_cost_usd: 1.5,
            max_requests: 900
          )
        ],
        system: system,
        max_turns: 8
      ]
    ]
  end
end

# A one-case subset, written out with the fixture path made absolute so the
# filtered copy under tmp/ still points at the checked-in repo. Same shape as
# `investigators.exs`.
# Its own corpus, not `eval/corpus/v1`. That one is the *recorded* gate: the
# nightly replays `eval/recordings/v1.json` against a blessed baseline and
# never calls a model. This case cannot live there, and not for a
# bookkeeping reason — `Lemieux.Benchmark.Runtime.Native` equips one tool set
# for every task in a manifest, so the corpus cannot express "this parent
# holds `delegate` and not `read`", which is the whole premise above. Run
# under the gate it answered 42500 by reading the files directly, passed its
# grader, and measured nothing.
corpus = "eval/corpus/experiments-v1"
case_id = "case_01M2S6FMZKDX7YKSPQ0RCQ5C5V"
manifest = corpus |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()

tasks =
  manifest["tasks"]
  |> Enum.filter(&(&1["id"] == case_id))
  |> Enum.map(&Map.update!(&1, "cwd", fn cwd -> Path.expand(Path.join(corpus, cwd)) end))

tasks == [] && raise "#{case_id} is not in #{corpus}/manifest.json"

suite = Path.join(output_dir, "manifest.json")
File.mkdir_p!(output_dir)
File.write!(suite, JSON.encode!(Map.put(manifest, "tasks", tasks)))

[
  suite: suite,
  # Eight was the most `Lemieux.Subagent.Definition` used to permit, and it
  # solved 1 of 3 where six solved 0 of 3 — turns were the binding factor, and
  # the old ceiling was itself part of the problem. `nil` takes the definition
  # default, which is now high enough that the deadline decides instead.
  # `LMX_DELEGATE_BUDGET_TURNS` selects the arms: a comma-separated list of
  # child turn counts, where `default` takes the definition's own.
  #
  # `1` is the fabrication probe rather than a budget one. A child with a
  # single turn cannot both look and answer, so findings are zero by
  # construction on any model — and a parent holding `delegate` and no `read`
  # then has nothing to answer from, so anything it reports is invented. Eight
  # produced that condition on one model by accident; one produces it on
  # purpose.
  agents:
    System.get_env("LMX_DELEGATE_BUDGET_TURNS", "8,default")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn
      "default" -> {"child-default-turns", Lemieux.Agent.Session, arm.(nil)}
      n -> {"child-#{n}-turns", Lemieux.Agent.Session, arm.(String.to_integer(n))}
    end),
  benchmark_options: [
    # One attempt in flight: a delegating attempt is a parent plus a child, and
    # req_llm's streaming pool is shared. See docs/subagents.md.
    max_concurrency: 1,
    repetitions: String.to_integer(System.get_env("LMX_DELEGATE_BUDGET_REPS", "3")),
    workspace_root: Path.join(output_dir, "workspaces"),
    output: Path.join(output_dir, "report.json")
  ]
]
