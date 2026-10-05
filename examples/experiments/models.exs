# One corpus, several models, nothing else different.
#
#     set -a; . ./.env; set +a
#     LMX_MODELS=zai_coding_plan:glm-5.3,ixway:gpt-5.6-luna \
#       mix lemieux.extension.eval examples/experiments/models.exs --allow-live
#     mix run examples/experiments/models_verdict.exs \
#       tmp/experiments/models/<run>/report.json
#
# The arms differ in exactly one factor: the model. Corpus, prompt, tools,
# turn limits, sampling and budgets are identical, so a difference in pass
# rate or in spend is the model and not the configuration around it.
#
# Why this is worth its own file. `Lemieux.Learning.Discovery` already evaluates
# a case across a model portfolio, but that lane speaks `Extension.Profile`,
# whose tool vocabulary is closed to read/write/edit/bash — it cannot express
# `delegate`, or any host tool. This one runs `Lemieux.Agent.Session` directly,
# so whatever a host can equip, a comparison can measure.
#
# Environment:
#   LMX_MODELS        comma-separated models; one arm each. Required.
#   LMX_MODELS_CORPUS corpus directory; default eval/corpus/v1
#   LMX_MODELS_CASES  comma-separated case ids; default every case
#   LMX_MODELS_TOOLS  read,write,edit,bash by default; "none" for a
#                     tool-less arm
#   LMX_MODELS_REPS   attempts per case per model; default 3. A single
#                     attempt measures a sample, not a model.
#   LMX_MODELS_TURNS  parent turn limit; default 24
#   LMX_MODELS_RUN    run directory name under tmp/experiments/models

alias Lemieux.CLI.Options
alias Lemieux.CLI.Runtime
alias Lemieux.Tools

models =
  System.get_env("LMX_MODELS", "")
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)

models == [] && raise "set LMX_MODELS to a comma-separated list of models"

corpus = System.get_env("LMX_MODELS_CORPUS", "eval/corpus/v1")
run = System.get_env("LMX_MODELS_RUN", Date.to_iso8601(Date.utc_today()))
output_dir = Path.join(["tmp/experiments/models", run])

tools =
  case System.get_env("LMX_MODELS_TOOLS", "read,write,edit,bash") do
    "none" ->
      []

    csv ->
      catalog = %{
        "read" => Tools.Read,
        "write" => Tools.Write,
        "edit" => Tools.Edit,
        "bash" => Tools.Bash,
        "elixir" => Tools.Eval
      }

      csv
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn name ->
        Map.get(catalog, name) ||
          raise "unknown tool #{name}; known: #{Enum.join(Map.keys(catalog), ", ")}"
      end)
  end

# An `ixway:` model resolves only through a provider carrying the gateway
# connection, so the route follows the model rather than the file. Built per
# attempt: provider state must not be shared across arms.
provider = fn model ->
  fn ->
    if String.starts_with?(model, "ixway:") do
      {:ok, options} = Options.parse([])
      Runtime.provider(options)
    else
      Lemieux.Providers.ReqLLM.new(receive_timeout: 120_000)
    end
  end
end

manifest = corpus |> Path.join("manifest.json") |> File.read!() |> JSON.decode!()

wanted =
  case System.get_env("LMX_MODELS_CASES") do
    nil -> nil
    csv -> csv |> String.split(",", trim: true) |> Enum.map(&String.trim/1) |> MapSet.new()
  end

tasks =
  manifest["tasks"]
  |> Enum.filter(&(is_nil(wanted) or MapSet.member?(wanted, &1["id"])))
  |> Enum.map(&Map.update!(&1, "cwd", fn cwd -> Path.expand(Path.join(corpus, cwd)) end))

tasks == [] && raise "no cases selected from #{corpus}/manifest.json"

File.mkdir_p!(output_dir)
suite = Path.join(output_dir, "manifest.json")
File.write!(suite, JSON.encode!(Map.put(manifest, "tasks", tasks)))

arm = fn model ->
  fn ->
    [
      provider: provider.(model).(),
      model: model,
      sessions_dir: Path.join(output_dir, "sessions"),
      session_options: [
        tools: tools,
        system: Lemieux.Prompt.default(),
        max_turns: String.to_integer(System.get_env("LMX_MODELS_TURNS", "24")),
        params: [max_tokens: 4096]
      ]
    ]
  end
end

[
  suite: suite,
  agents: Enum.map(models, &{&1, Lemieux.Agent.Session, arm.(&1)}),
  benchmark_options: [
    # One attempt in flight: several models streaming at once contend for
    # req_llm's per-host pool, and a queued stream is a slower arm rather than
    # a worse model. See docs/subagents.md.
    max_concurrency: 1,
    repetitions: String.to_integer(System.get_env("LMX_MODELS_REPS", "3")),
    workspace_root: Path.join(output_dir, "workspaces"),
    output: Path.join(output_dir, "report.json")
  ]
]
