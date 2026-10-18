defmodule Lemieux.CLI.Runtime.Evaluation do
  @moduledoc """
  **Experimental.** May change in any 0.x release.

  Paired evaluation of the effective `lmx` harness through its ordinary assembly.

  `prepare/3` calls `Lemieux.CLI.Runtime.with_workspace/2` and `prepare/2`,
  including personal and repository layers, current extension decisions and
  resume reconstruction. An unchanged control is the ordinary prepared harness.
  A candidate may append instructions, redescribe existing enabled local tools,
  or change explicitly frozen generation fields. It cannot replace a catalog,
  change executors or relax host constraints. Unsupported edits are refused,
  including an edit masked by a host override; testing an unchanged candidate
  under a changed name would misattribute a result.

  The qualification freezes resolved configuration and code identities. Private
  environment and callback state contributes only an opaque digest, never a
  serialized value. Providers, credentials, stores and policy are supplied anew
  by the host. No snapshot can construct a runtime. `compatible?/2` is an exact,
  conservative cache check: workspace paths, transcript history, current date,
  host state or code changes invalidate reuse. Equivalent copied workspaces are
  separate qualifications, not silently normalized identities. Cache reuse
  requires a non-secret host `:provider_identity` (`"id"` and SHA-256 `"sha256"`)
  binding the serving revision. Opaque process/reference state disables reuse;
  a host must revise its identity when external mutable serving behavior changes.

  `runtime/4` is a benchmark runtime. It assembles inside each attempt's actual
  workspace and attaches the qualification to request harness snapshots and
  terminal evidence. It qualifies this host configuration, task workspace,
  model and frozen edit only. Dynamic request hooks, discovered MCP catalogs
  and tool results remain facts of the actual request snapshots; preparation
  alone does not claim that a request was authorized or executed.
  """
  @behaviour Lemieux.Benchmark.Runtime

  alias Lemieux.Agent.Session
  alias Lemieux.Benchmark.Runtime, as: BenchmarkRuntime
  alias Lemieux.Benchmark.Task
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.Runtime.Evaluation.Fingerprint
  alias Lemieux.CLI.Runtime.Evaluation.ProfileDelta
  alias Lemieux.Contract
  alias Lemieux.Harness
  alias Lemieux.Learning.Discovery.Surface
  alias Lemieux.Prompt
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool
  alias Lemieux.Tool.Override
  alias Lemieux.Tools

  @generation %{
    "temperature" => :temperature,
    "max_tokens" => :max_tokens,
    "reasoning_effort" => :reasoning_effort
  }

  @doc "Assembles from fresh host inputs, freezes the control and applies only the named surface."
  @spec prepare(options :: Options.t(), host :: keyword(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare(%Options{} = options, host, opts \\ []) do
    changes = Keyword.get(opts, :changes, %{})
    surface = Keyword.get(opts, :surface, [])

    with :ok <- provider_identity(host[:provider_identity]),
         :ok <- validate(changes, surface),
         {:ok, host} <- Runtime.with_workspace(options, host),
         {:ok, prepared} <- Runtime.prepare(options, host),
         {:ok, control} <- Fingerprint.build(prepared, options, host),
         :ok <- expected(control, opts),
         {:ok, harness} <- edit(prepared.harness, changes),
         :ok <- constrained(harness, prepared.options),
         {:ok, effective} <- Fingerprint.build(%{prepared | harness: harness}, options, host),
         :ok <- stable_authority(control, effective) do
      qualification =
        %{
          "schema_version" => 1,
          "lane" => "effective_lmx",
          "control" => control,
          "effective" => effective,
          "surface" => Enum.sort(surface),
          "intentional_changes" => changes,
          "qualification" => "current lmx host inputs and task workspace; no activation"
        }
        |> then(&Map.put(&1, "sha256", Contract.digest(&1)))

      {:ok, prepared |> Map.put(:harness, harness) |> Map.put(:qualification, qualification)}
    end
  end

  @doc "Verifies data integrity; it grants no authority and restores no executable configuration."
  @spec verify(qualification :: map()) :: :ok | {:error, term()}
  def verify(
        %{
          "schema_version" => 1,
          "lane" => "effective_lmx",
          "control" => control,
          "effective" => effective
        } = qualification
      )
      when is_map(control) and is_map(effective) do
    with :ok <- Contract.verify_digest(qualification, "sha256"),
         :ok <- Contract.verify_digest(qualification["control"], "sha256") do
      Contract.verify_digest(qualification["effective"], "sha256")
    end
  rescue
    _invalid -> {:error, :invalid_runtime_qualification}
  end

  def verify(_invalid), do: {:error, :invalid_runtime_qualification}

  @doc "True only for intact qualifications with the same control, surface and intentional edit."
  @spec compatible?(previous :: map(), current :: map()) :: boolean()
  def compatible?(previous, current),
    do:
      verify(previous) == :ok and verify(current) == :ok and
        previous["control"]["cacheable"] == true and previous["effective"]["cacheable"] == true and
        previous == current

  @doc "Data-only binding a campaign freezes beside its host-supplied runtime factory."
  @spec identity(prepared :: map()) :: map()
  def identity(%{qualification: qualification}) do
    %{
      "id" => "lemieux.effective-lmx/v1",
      "sha256" => qualification["sha256"],
      "control_sha256" => qualification["control"]["sha256"],
      "surface" => qualification["surface"]
    }
  end

  @doc "Builds a benchmark runtime; host options may contain a fresh zero-arity provider factory."
  @spec runtime(name :: String.t(), options :: Options.t(), host :: keyword(), opts :: keyword()) ::
          BenchmarkRuntime.t()
  def runtime(name, options, host, opts \\ []),
    do: BenchmarkRuntime.new(name, __MODULE__, options: options, host: host, evaluation: opts)

  @doc "Maps a portable profile's append-only text delta onto the actual CLI assembly."
  @spec factory(options :: Options.t(), host :: keyword(), opts :: keyword()) :: function()
  def factory(options, host, opts) do
    parent = Keyword.fetch!(opts, :parent_profile)

    fn name, profile, provider, runtime_opts ->
      with {:ok, changes} <- ProfileDelta.changes(parent, profile),
           true <- profile["model"] == options.model do
        host =
          Keyword.merge(Keyword.get(runtime_opts, :session, []), host)
          |> Keyword.put(:provider, provider)
          |> Keyword.put_new(
            :store,
            JSONL.new(Keyword.fetch!(runtime_opts, :sessions_dir))
          )

        {:ok, runtime(name, options, host, Keyword.put(opts, :changes, changes))}
      else
        false -> {:error, :evaluation_model_differs_from_host}
        error -> error
      end
    end
  end

  @impl true
  def run(%Task{} = task, opts) do
    host = opts |> Keyword.fetch!(:host) |> Keyword.put(:cwd, task.cwd) |> fresh_provider()

    with {:ok, prepared} <- prepare(Keyword.fetch!(opts, :options), host, opts[:evaluation] || []) do
      harness = evidence(prepared.harness, prepared.qualification)

      session =
        prepared.options
        |> Keyword.put(:harness, harness)
        |> maybe_resume(prepared.resume)

      agent_opts = [
        provider: Keyword.fetch!(prepared.options, :provider),
        model: prepared.model,
        supervisor: Keyword.fetch!(prepared.options, :supervisor),
        detach_runtime: not Keyword.has_key?(host, :supervisor),
        session_options: session
      ]

      qualify(
        Session.run(Map.take(task, [:prompt, :cwd, :timeout_ms]), agent_opts),
        prepared.qualification
      )
    end
  end

  defp fresh_provider(host) do
    case host[:provider] do
      factory when is_function(factory, 0) -> Keyword.put(host, :provider, factory.())
      _provider -> host
    end
  end

  defp maybe_resume(opts, nil), do: opts
  defp maybe_resume(opts, resume), do: Keyword.put(opts, :resume, resume)

  defp qualify({:ok, observation}, qualification),
    do: {:ok, Map.put(observation, "runtime_qualification", qualification)}

  defp qualify({:error, reason, observation}, qualification),
    do: {:error, reason, Map.put(observation, "runtime_qualification", qualification)}

  defp qualify(error, _qualification), do: error

  defp evidence(harness, qualification) do
    reference = Map.take(qualification, ~w(lane sha256 surface intentional_changes))
    reference = Map.put(reference, "control_sha256", qualification["control"]["sha256"])
    reference = Map.put(reference, "effective_sha256", qualification["effective"]["sha256"])

    Harness.update_harness_context(harness, fn context ->
      Map.update(
        context,
        "workflow",
        %{"evaluation" => reference},
        &Map.put(&1, "evaluation", reference)
      )
    end)
  end

  defp expected(%{"sha256" => digest}, opts) do
    case Keyword.get(opts, :expected_control_sha256) do
      nil -> :ok
      ^digest -> :ok
      _changed -> {:error, :evaluation_control_drift}
    end
  end

  defp provider_identity(nil), do: :ok

  defp provider_identity(%{"id" => id, "sha256" => sha} = identity)
       when is_binary(id) and byte_size(id) in 1..128 and is_binary(sha) do
    if map_size(identity) == 2 and Regex.match?(~r/\A[a-f0-9]{64}\z/, sha),
      do: :ok,
      else: {:error, :invalid_provider_identity}
  end

  defp provider_identity(_invalid), do: {:error, :invalid_provider_identity}

  defp validate(changes, surface) when is_map(changes) and is_list(surface) do
    if Enum.all?(surface, &is_binary/1),
      do: validate_paths(changes, surface),
      else: {:error, :invalid_surface}
  end

  defp validate(_changes, _surface), do: {:error, :invalid_surface}

  defp validate_paths(changes, surface) do
    known = Map.keys(changes) -- ~w(system_suffix tool_descriptions generation)

    paths =
      Surface.changed_paths(
        %{"system_suffix" => nil, "tool_descriptions" => %{}, "generation" => %{}},
        changes
      )

    # Missing optional keys are not edits; changed_paths also reports removals.
    paths = Enum.filter(paths, &Map.has_key?(changes, hd(String.split(&1, "."))))

    outside =
      Enum.reject(paths, fn path ->
        Enum.any?(surface, &(path == &1 or String.starts_with?(path, &1 <> ".")))
      end)

    cond do
      known != [] -> {:error, :unsupported_change}
      outside != [] -> {:error, {:outside_surface, outside}}
      true -> :ok
    end
  end

  defp edit(harness, changes) when map_size(changes) == 0, do: {:ok, harness}

  defp edit(harness, changes) do
    with {:ok, system} <- suffix(harness.system, changes["system_suffix"]),
         {:ok, tools} <- descriptions(harness, Map.get(changes, "tool_descriptions", %{})),
         {:ok, generation} <- generation(Map.get(changes, "generation", %{})) do
      {effort, params} = Keyword.pop(generation, :reasoning_effort, harness.reasoning_effort)

      {:ok,
       %{
         harness
         | system: system,
           tools: tools,
           reasoning_effort: effort,
           params:
             if(params == [],
               do: harness.params,
               else: Keyword.merge(harness.params || [], params)
             )
       }}
    end
  end

  defp suffix(system, nil), do: {:ok, system}
  defp suffix(:default, suffix), do: suffix(Prompt.default(), suffix)

  defp suffix(system, suffix) when is_binary(suffix) and byte_size(suffix) in 1..65_536,
    do: {:ok, (system || "") <> "\n\n" <> suffix}

  defp suffix(_system, _suffix), do: {:error, :invalid_system_suffix}

  defp descriptions(harness, descriptions)
       when is_map(descriptions) and map_size(descriptions) == 0,
       do: {:ok, harness.tools}

  defp descriptions(harness, descriptions) when is_map(descriptions) do
    catalog = harness.tools || Tools.default()

    enabled =
      Harness.explain(harness)["tools"] |> Enum.filter(& &1["enabled"]) |> Enum.map(& &1["name"])

    allowed = Enum.map(catalog, &Tool.name/1) -- (harness.disabled_tools || [])

    if Enum.all?(descriptions, fn {name, text} ->
         name in allowed and name in enabled and valid_description?(text)
       end) do
      {:ok,
       Enum.map(catalog, fn tool ->
         case descriptions[Tool.name(tool)] do
           nil -> tool
           text -> Override.new!(tool, description: text)
         end
       end)}
    else
      {:error, :invalid_tool_description}
    end
  end

  defp descriptions(_harness, _descriptions), do: {:error, :invalid_tool_description}

  defp valid_description?(text),
    do: is_binary(text) and byte_size(text) in 1..16_384 and String.trim(text) != ""

  defp stable_authority(control, effective) do
    changes = Harness.diff(authority_projection(control), authority_projection(effective))

    if changes == %{},
      do: :ok,
      else: {:error, {:assembly_changed_during_preparation, Map.keys(changes)}}
  end

  defp authority_projection(freeze) do
    freeze
    |> Map.drop(~w(sha256 system catalog generation))
    |> Map.update!("session_configuration", &Map.drop(&1, ~w(params reasoning_effort)))
    |> Map.update!("catalog_policy", &catalog_policy/1)
  end

  defp catalog_policy(policy), do: Map.update!(policy, "tools", &tool_visibility/1)
  defp tool_visibility(tools), do: Enum.map(tools, &Map.take(&1, ~w(name enabled)))

  defp generation(generation) when is_map(generation) do
    if Enum.all?(generation, &valid_generation?/1),
      do: {:ok, Enum.map(generation, fn {name, value} -> {@generation[name], value} end)},
      else: {:error, :invalid_generation}
  end

  defp generation(_generation), do: {:error, :invalid_generation}
  defp valid_generation?({"max_tokens", value}), do: is_integer(value) and value > 0

  defp valid_generation?({"temperature", value}),
    do: is_number(value) and value >= 0 and value <= 2

  defp valid_generation?({"reasoning_effort", value}),
    do: value in ~w(none minimal low medium high xhigh max)

  defp valid_generation?(_unknown), do: false

  defp constrained(harness, options) do
    constrained = Runtime.constrain(harness, options)

    case Enum.find(
           Harness.session_fields(),
           &(Map.fetch!(constrained, &1) != Map.fetch!(harness, &1))
         ) do
      nil -> :ok
      field -> {:error, {:host_constraint, field}}
    end
  end
end
