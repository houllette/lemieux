defmodule Lemieux.Learning.Builder.Scaffold do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Deterministic, source-preserving starter projects for the guided builder.

  The starter has a real agent and a deliberately failing acceptance case. A
  developer must define task-specific acceptance before obtaining a passing
  report; an always-green placeholder would reward an unfinished extension.

  The starter depends on the Lemieux release that generated it, from Hex, as
  `~> VERSION`: the API it was written against, plus that line's patch
  releases. `LEMIEUX_EXTENSION_BASE`, an absolute path to a checkout, replaces
  that dependency while developing against another source tree. Starters used
  to pin a Git revision instead, which tied every generated project to a
  commit of this repository's history rather than to a release anyone could
  install, and to a revision that predated the API it was generated for.

  The generated `bench/workbench.exs` asks `lmx` for its provider
  (`Lemieux.CLI.Runtime.provider/0`), so a benchmark uses the route and the
  saved keys the person already set `lmx` up with. That function is `lmx`'s
  own assembly rather than the documented extension API, and the file says so
  next to the call, naming `Lemieux.Providers.ReqLLM.new/0` as the documented
  alternative; the `~> VERSION` requirement keeps a change to it within one
  release line.
  """

  alias Lemieux.Extension.Profile
  alias Lemieux.Learning.Extension.Export

  @doc "Creates a new Mix extension without compiling code, installing dependencies or running it."
  @spec create(destination :: Path.t(), name :: String.t(), profile :: map()) ::
          {:ok, map()} | {:error, term()}
  def create(destination, name, profile) do
    with :ok <- valid_name(name), :ok <- Profile.validate(profile) do
      stage = Path.join(System.tmp_dir!(), "lemieux-scaffold-" <> Lemieux.ID.generate())
      :ok = File.mkdir(stage)

      try do
        files = files(name, profile)

        Enum.each(files, fn {path, body} ->
          target = Path.join(stage, path)
          File.mkdir_p!(Path.dirname(target))
          File.write!(target, body)
        end)

        manifest = %{
          "schema_version" => 1,
          "module" => Macro.camelize(name),
          "files" => Map.keys(files) |> Enum.sort()
        }

        File.write!(Path.join(stage, "lemieux-extension.json"), JSON.encode!(manifest))
        Export.export(stage, destination)
      after
        File.rm_rf(stage)
      end
    end
  end

  defp valid_name(name) when is_binary(name) do
    if Regex.match?(~r/\A[a-z][a-z0-9]*(?:_[a-z0-9]+)*\z/, name) and byte_size(name) <= 60,
      do: :ok,
      else: {:error, :invalid_extension_name}
  end

  defp valid_name(_name), do: {:error, :invalid_extension_name}

  defp files(name, profile) do
    module = Macro.camelize(name)

    %{
      ".formatter.exs" => "[inputs: [\"{mix,.formatter}.exs\", \"{lib,test}/**/*.{ex,exs}\"]]\n",
      "mix.exs" => """
      defmodule #{module}.MixProject do
        use Mix.Project
        def project do
          [app: :#{name}, version: "0.1.0", elixir: "~> 1.19",
           deps: [lemieux(),
                  {:ex_ratatui, "~> 0.17", optional: true}]]
        end
        def application, do: [extra_applications: [:logger]]
        defp lemieux do
          case System.get_env("LEMIEUX_EXTENSION_BASE") do
            nil -> {:lemieux, "#{lemieux_requirement()}"}
            path -> {:lemieux, path: path}
          end
        end
      end
      """,
      "lib/#{name}.ex" => """
      defmodule #{module} do
        @moduledoc "A tuned Lemieux session extension."
        @behaviour Lemieux.Agent
        @external_resource Path.expand("../priv/profile.json", __DIR__)
        @profile @external_resource |> File.read!() |> JSON.decode!()
        @spec profile() :: map()
        def profile, do: @profile
        @impl Lemieux.Agent
        def configure(profile), do: configure(profile, [])
        @spec configure(profile :: map(), opts :: keyword()) :: {:ok, keyword(), map()} | {:error, term()}
        def configure(profile, opts) do
          Lemieux.Extension.Profile.configure(profile, Keyword.put(opts, :tool_registry, tool_registry()))
        end
        @doc "Register native Lemieux.Tool modules or configured tool structs here."
        @spec tool_registry() :: [Lemieux.Tool.t()]
        def tool_registry, do: []
        @doc "Run this compiled extension in the TUI or headless CLI."
        @spec cli(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
        def cli(argv \\\\ [], opts \\\\ []) do
          opts = opts |> Keyword.put(:tool_registry, tool_registry()) |> Keyword.put(:extension_name, inspect(__MODULE__))
          Lemieux.Extension.CLI.run(profile(), argv, opts)
        end
        @impl Lemieux.Agent
        def run(input, opts), do: Lemieux.Extension.Profile.run(input, opts)
      end
      """,
      "priv/profile.json" => JSON.encode!(profile),
      "BUILDING.md" => """
      # Extension development

      Status: scaffold only; unassessed.

      Record the agreed job and acceptance criteria here. Real development cases,
      model/effort selection, refinement and independent confirmation remain
      outstanding. Save small findings as work proceeds; record failed attempts
      as well as successful ones. Keep credentials and hidden evidence out.
      """,
      "bench/cases/example/input.txt" =>
        "Replace this with a representative development input.\n",
      "bench/grade.sh" =>
        "#!/bin/sh\n# Replace with a task-specific check. The starter must fail.\necho 'Acceptance criteria have not been implemented'\nexit 1\n",
      "bench/suite.json" =>
        JSON.encode!(%{
          "version" => 1,
          "tasks" => [
            %{
              "id" => "example",
              "prompt" => "Replace with the task to perform.",
              "cwd" => "cases/example",
              "timeout_ms" => 120_000,
              "metadata" => %{"cluster_id" => "example", "exposure" => "development"},
              "grader" => %{"command" => ["sh", "bench/grade.sh", "{answer}", "{cwd}"]}
            }
          ]
        }),
      "bench/models.json" =>
        JSON.encode!([
          %{"model" => profile["model"], "efforts" => [profile["options"]["reasoning_effort"]]}
        ]),
      "bench/workbench.exs" => workbench(module, profile),
      "bench/freeze.exs" => "[source: File.cwd!(), profile: #{module}.profile()]\n",
      "README.md" => """
      # #{module}

      A session-based Lemieux extension. Edit `priv/profile.json` to tune its
      instructions, tools, provider:model, effort and bounds; then recompile.
      Prefer deterministic Elixir modules for repeatable preparation, checks,
      parsing and policy. Implement reusable tools under `lib/`, register them
      in `tool_registry/0`, and select their names in `priv/profile.json`.
      Their schema, timeout/output bounds and effects must reflect what they do.
      `configure/2` is shared by benchmarks and the Agent; `cli/2` uses the same
      registry in the TUI and headless runtime. Test helpers without a model.

      Hex dependencies belong in this extension's `mix.exs`, not Lemieux core.
      Include `mix.lock`, tool/pipeline sources and fixtures in the export manifest.
      Do not package deps/_build or credentials; dependencies resolve in the Mix
      consumer. Record required external executables and environment assumptions.

      Run `mix deps.get` to fetch Lemieux from Hex (`#{lemieux_requirement()}`, the
      release that generated this project). For local development against a
      checkout, set `LEMIEUX_EXTENSION_BASE` to its absolute path. Raise the
      requirement deliberately when you upgrade, and rerun the tests.

      The optional ex_ratatui dependency enables this project's TUI. A consuming
      host that wants the TUI must opt into ex_ratatui too; headless hosts need
      no terminal dependency.

      Run from the compiled Mix project with native tools:

          mix run -e '#{module}.cli()'
          mix run -e '#{module}.cli(["run", "TASK"])'

      For profiles selecting only built-in tools, the standalone binary also works:

          lmx --extension-profile priv/profile.json
          lmx run "TASK" --extension-profile priv/profile.json

      Define real acceptance in `bench/grade.sh` (the starter deliberately fails).
      Set a comparison budget in `bench/workbench.exs`, select models/efforts in
      `bench/models.json`, then:

          mix lemieux.extension.compare bench/workbench.exs bench/models.json
          mix lemieux.extension.compare bench/workbench.exs bench/models.json --allow-live
          mix lemieux.extension.freeze bench/freeze.exs ../frozen-candidate

      The first compare command is a plan only. Development comparisons and
      source exports are unassessed. Use independent confirmation before a
      confirmed export; keep its holdouts, reports and exposure ledger private
      and outside this project. Do not give hidden cases to the builder.
      """
    }
  end

  # The release that generated the starter and that line's patch releases:
  # `~> 0.8.0` admits 0.8.x and refuses 0.9.0, whose API may have moved.
  defp lemieux_requirement, do: "~> " <> Lemieux.version()

  defp workbench(module, profile) do
    cap = profile["options"]["max_cost_usd"]

    budget =
      if profile["options"]["usage_mode"] == "quota",
        do: [
          usage_mode: :quota,
          max_attempts: 32,
          max_requests_per_attempt: profile["options"]["max_requests"]
        ],
        else: [cost_cap_usd: cap * 2, max_cost_per_attempt_usd: cap]

    """
    # Resolve the grader outside copied task workspaces. This is development
    # data; confirmation uses an independently frozen evaluator.
    suite = "bench/suite.json" |> File.read!() |> JSON.decode!()
    tasks = Enum.map(suite["tasks"], fn task ->
      task = Map.update!(task, "cwd", &Path.expand(&1, "bench"))
      update_in(task, ["grader", "command"], fn
        ["sh", path | args] -> ["sh", Path.expand(path) | args]
        command -> command
      end)
    end)
    File.mkdir_p!("tmp")
    File.write!("tmp/builder-suite.json", JSON.encode!(Map.put(suite, "tasks", tasks)))
    # The provider `lmx` itself would use with no flags: its route, and the
    # keys in the environment or saved in ~/.lmx/config.json.
    # `Lemieux.CLI.Runtime.provider/0` belongs to lmx's own assembly, outside
    # the documented extension API, so a Lemieux patch release may change it.
    # To depend on the documented API alone, use `Lemieux.Providers.ReqLLM.new()`,
    # which reads keys from the environment only.
    provider = Lemieux.CLI.Runtime.provider()
    [suite: "tmp/builder-suite.json", workbench_dir: "tmp/workbench", execution: :live,
     search_provider: provider,
     agents: [{"baseline", #{module}, fn ->
       {:ok, options, _} = #{module}.configure(#{module}.profile(), provider: provider)
       options
     end}],
     benchmark_options: #{inspect([repetitions: 1, max_concurrency: 1] ++ budget)}]
    """
  end
end
