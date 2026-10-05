# The read-only investigator experiment from docs/subagents.md:
# the same parent session with and without the `delegate` tool, paired on
# every case of the investigators corpus.
#
#     set -a; . ./.env; set +a
#     LMX_INVESTIGATORS_MODEL=zai_coding_plan:glm-5.3 \
#       mix lemieux.extension.eval examples/experiments/investigators.exs --allow-live
#     LMX_INVESTIGATORS_MODEL=openai:gpt-5.6-luna \
#       mix lemieux.extension.eval examples/experiments/investigators.exs --allow-live
#     mix run examples/experiments/investigators_verdict.exs tmp/experiments/investigators/<run>/report.json
#
# This file is executable configuration for `mix lemieux.extension.eval`,
# which is `Lemieux.Benchmark.run/3` over two `Lemieux.Agent.Session`
# runtimes. That lane was chosen deliberately: `Lemieux.Extension.Profile`
# has a closed tool vocabulary (read/write/edit/bash) and cannot carry
# `delegate`, so neither profile-pairing lane (`lemieux.discovery.confirm`,
# `lemieux.extension.confirm`) can express the variant arm. The two arms
# below differ in exactly one factor: the delegating arm gets one bounded
# read-only investigator definition, the tree budget that definition needs,
# and one sentence telling the parent when to use it. System prompt, tools,
# turn limit, sampling parameters and the parent's own budget are identical.
#
# Environment:
#   LMX_INVESTIGATORS_MODEL   both arms' model, as provider:model. Required:
#                             every attempt is a live, billed or
#                             quota-consuming call, so nothing picks a
#                             provider for you
#   LMX_INVESTIGATORS_USAGE   "quota" or "metered"; default quota for the
#                             Z.AI Coding Plan, metered for anything else
#   LMX_INVESTIGATORS_CASES   comma-separated case ids to run a subset
#                             (a filtered manifest is written into the run dir)
#   LMX_INVESTIGATORS_CORPUS  corpus directory; default eval/corpus/investigators-v1
#                             (the wiring smoke test points it at discovery-v1)
#   LMX_INVESTIGATORS_RUN     run directory name under tmp/experiments/investigators
#   LMX_INVESTIGATORS_CONCURRENCY  attempts in flight; default 1. A delegating
#                                  attempt is one parent plus up to three
#                                  children, and req_llm's streaming pool has
#                                  eight connections per VM: two attempts in
#                                  flight exhausted it ("excess queuing for
#                                  connections") and failed children only.
#   LMX_INVESTIGATORS_COST_CAP     metered only: hard cap in dollars for the
#                                  whole run; default 1.40
#
# Nothing here reads ~/.lmx/config.json: the provider is a direct ReqLLM
# connection keyed from the environment, so the measurement is of the model
# named above and not of whatever gateway the interactive CLI routes through.

alias Lemieux.Subagent.Definition
alias Lemieux.Tools

model =
  System.get_env("LMX_INVESTIGATORS_MODEL") ||
    raise "set LMX_INVESTIGATORS_MODEL=provider:model to choose the model both arms run on"

usage_mode =
  System.get_env(
    "LMX_INVESTIGATORS_USAGE",
    if(String.starts_with?(model, "zai_coding_plan:"), do: "quota", else: "metered")
  )

metered? = usage_mode == "metered"

slug = String.replace(model, ~r/[^A-Za-z0-9.-]/, "_")

run =
  System.get_env(
    "LMX_INVESTIGATORS_RUN",
    "#{Date.to_iso8601(Date.utc_today())}-#{slug}"
  )

output_dir = Path.join("tmp/experiments/investigators", run)
File.mkdir_p!(output_dir)

corpus =
  Path.expand(System.get_env("LMX_INVESTIGATORS_CORPUS", "eval/corpus/investigators-v1"))

manifest_path = Path.join(corpus, "manifest.json")

# A subset run rewrites the manifest with absolute fixture paths so the
# filtered copy under tmp/ still points at the checked-in fixtures.
suite =
  case System.get_env("LMX_INVESTIGATORS_CASES") do
    nil ->
      manifest_path

    csv ->
      wanted = csv |> String.split(",", trim: true) |> MapSet.new()
      manifest = manifest_path |> File.read!() |> JSON.decode!()

      tasks =
        manifest["tasks"]
        |> Enum.filter(&MapSet.member?(wanted, &1["id"]))
        |> Enum.map(&Map.update!(&1, "cwd", fn cwd -> Path.join(corpus, cwd) end))

      missing = wanted |> MapSet.difference(MapSet.new(tasks, & &1["id"])) |> MapSet.to_list()
      if missing != [], do: raise(ArgumentError, "unknown case ids: #{inspect(missing)}")

      path = Path.join(output_dir, "manifest.json")
      File.write!(path, JSON.encode!(Map.put(manifest, "tasks", tasks)))
      path
  end

# req_llm streams through eight HTTP/1 pools of one connection each and picks
# a pool per request, so three or four concurrent streams (a parent plus its
# children) collide often enough that one child per group queued behind a
# busy connection for the whole pool timeout and died at its deadline having
# read one file. The second attempt at this run lost four of nine Luna
# children that way. The pool is sized here, before any session starts, by
# restarting :req_llm with wider pools; nothing else in the VM holds a
# connection at this point.
Application.put_env(:req_llm, :stream_pool_size, 8)
Application.put_env(:req_llm, :stream_pool_count, 8)
:ok = Application.stop(:req_llm)
{:ok, _started} = Application.ensure_all_started(:req_llm)

# The transport inactivity timeout defaults to 30 s, which the first attempt
# at this run showed a queued provider can exceed before a child's first
# token; two minutes matches the child deadline. The pool timeout is kept
# short on purpose so a pool problem surfaces as an error, not a hang.
provider = Lemieux.Providers.ReqLLM.new(receive_timeout: 120_000, pool_timeout: 10_000)

system =
  "You are a read-only investigator working in a repository checkout. Answer the " <>
    "question precisely: name the exact value, identifier or file path asked for and " <>
    "cite the files that establish it. Read the relevant files before answering rather " <>
    "than guessing, and follow any precedence or resolution rules the repository " <>
    "documents. Do not create, modify or delete any file. Finish with the answer as " <>
    "plain text."

# The one bounded prompt-tuning pass the experiment plan allows: the first
# wording ("when the question spans several files, use it once") produced
# no delegate call at all on the smoke case, because a parent with `bash`
# can read a ten-file fixture in one command. An arm that never delegates
# measures nothing, so the retained sentence tells the parent to start with
# the investigators and verify their findings itself.
delegate_hint =
  " Start by calling the delegate tool once with one to three read-only investigators, " <>
    "each assigned a distinct part of the question (for example one per file group or " <>
    "one per candidate explanation); then verify their findings against the files " <>
    "yourself and combine them into your answer."

investigator_prompt =
  "You are a read-only investigator. Read the files named or implied by your objective " <>
    "directly with the read tool (list a directory first when you do not know its " <>
    "contents), quote exact values and cite paths and line numbers. Report what you " <>
    "could not establish as an uncertainty instead of guessing. Do not propose or " <>
    "make any writes."

# Budgets. On the quota plan dollars are unknown by construction, so the
# parent is bounded by requests and the child/tree caps are nominal
# reservations; on a metered model every cap is a real dollar ceiling and
# the worst case per attempt (parent + tree) is what the benchmark reserves.
parent_budget = if metered?, do: [max_cost_usd: 0.10], else: [max_requests: 30]
child_cost = if metered?, do: 0.06, else: 0.25
tree_cost = if metered?, do: 0.20, else: 1.50

base_session = [
  system: system,
  tools: [Tools.Read, Tools.Bash],
  max_turns: 20,
  params: [max_tokens: 4096, temperature: 0.2],
  tool_timeout_ms: :timer.minutes(3)
]

investigator =
  Definition.new(
    id: "investigator",
    description: "Read files and return exact, source-cited findings for one bounded objective",
    system_prompt: investigator_prompt,
    model: model,
    tools: [Tools.Read],
    max_turns: 8,
    timeout: :timer.minutes(2),
    max_cost_usd: child_cost
  )

delegation = [
  system: system <> delegate_hint,
  # The host builds the delegate tool and hands it to the session like any
  # other tool. The cost gate prices a request's maximum possible output
  # before calling the provider; without the child bound a child could be
  # refused on paper.
  tools: [
    Tools.Read,
    Lemieux.Subagent.Delegate.new([investigator],
      snapshot: %{
        "kind" => "working_tree",
        "version" => 1,
        "corpus" => "investigators-v1"
      },
      max_cost_usd: tree_cost,
      child_options: [params: [max_tokens: 4096, temperature: 0.2]]
    )
  ]
]

agent = fn session ->
  fn ->
    [
      provider: provider,
      model: model,
      sessions_dir: Path.join(output_dir, "sessions"),
      session_options: Keyword.merge(base_session ++ parent_budget, session)
    ]
  end
end

cost_options =
  if metered?,
    do: [
      cost_cap_usd: String.to_float(System.get_env("LMX_INVESTIGATORS_COST_CAP", "1.40")),
      # The worst case one attempt can cost: the parent cap plus the tree cap.
      max_cost_per_attempt_usd: 0.10 + tree_cost
    ],
    else: []

[
  suite: suite,
  agents: [
    {"parent-only", Lemieux.Agent.Session, agent.([])},
    {"parent-delegate", Lemieux.Agent.Session, agent.(delegation)}
  ],
  benchmark_options:
    [
      max_concurrency: String.to_integer(System.get_env("LMX_INVESTIGATORS_CONCURRENCY", "1")),
      workspace_root: Path.join(output_dir, "workspaces"),
      output: Path.join(output_dir, "report.json")
    ] ++ cost_options
]
