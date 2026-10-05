defmodule Lemieux.Extension.Profile do
  @moduledoc """
  Portable tuning for session-based extensions, shared by agents and CLI hosts.

  This is harness tuning: instructions, tools, model, effort and bounds. It
  changes no model weights. Profiles contain only behavioral configuration;
  providers, keys, routes, stores and human channels remain host inputs.
  Native reusable tools are supplied as `:tool_registry` by compiled extension
  code and selected by name in the profile. They run through the ordinary tool
  lifecycle, hooks and transcript. Built-in names cannot be shadowed. Use
  `Lemieux.Extension.CLI.run/3` to pass the same registry to either CLI interface.
  Arbitrary multi-stage Elixir agents still own their own interactive adapter.

  The closed option set prevents misspelled settings from silently disappearing.
  Interactive hosts may add `ask_user`; headless hosts return questions in their
  answer. The core task instructions and generation settings remain identical.

  ## A data-only extension

  A profile is a `Lemieux.Extension` whose code is a JSON document. `init/1`
  takes `profile:`, `provider:` (the effort is checked against it) and
  `tool_registry:`, and `apply/2` sets the prompt, the catalog with its
  descriptions, the workflow host tool, the budgets and the generation
  parameters — what `session_options/3` has always returned, which is now
  that callback over an empty harness. Two things are not on the harness
  because they are host authority: the **model**, which a host reads with
  `model/1` and passes itself (`Lemieux.CLI.ExtensionExperience` does), and
  the provider. The profile's digest and kind go into
  `harness_context["extensions"]["session_profile"]` as before, and
  `describe/1` repeats them in the `"applied"` list.

  Names in JSON select trusted, already compiled code. A profile never
  resolves module names or loads source; an unknown name remains an error.

  ## Tool descriptions

  `options.tool_descriptions` is the one optional key: a map from a listed
  tool name to the description the model is shown for it, applied through
  `Lemieux.Tool.Override` so execution is untouched. It exists because tool
  interface text is the surface where harness edits pay and transfer between
  models (see that module); a profile that could only change the system prompt
  would leave a discovery candidate unable to express the one edit that
  matters. It is optional rather than required so every existing profile stays
  valid byte for byte, which keeps recorded profile digests — and the
  qualification bound to them — meaningful. The host workflow tool cannot be
  described from a profile: its text belongs to the host that constructs it,
  and a profile that could redescribe it would be tuning a tool it does not
  control.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Agent.Session
  alias Lemieux.Contract
  alias Lemieux.Harness
  alias Lemieux.Learning.Builder.Workflow
  alias Lemieux.Provider
  alias Lemieux.Providers.ReqLLM
  alias Lemieux.Tool
  alias Lemieux.Tool.Override

  @typedoc """
  What `init/1` resolves: the validated profile, the provider its effort was
  checked against, the compiled tools its names select, and the designation
  a host gave it for the snapshot.
  """
  @type state :: %{
          profile: map(),
          provider: Provider.t(),
          registry: %{optional(String.t()) => Tool.t()},
          name: String.t() | nil
        }

  @tools %{
    "read" => Lemieux.Tools.Read,
    "write" => Lemieux.Tools.Write,
    "edit" => Lemieux.Tools.Edit,
    "bash" => Lemieux.Tools.Bash
  }
  @host_tools ~w(extension_workflow)
  @options ~w(system max_turns max_tokens max_cost_usd reasoning_effort temperature)
  # Dropped before the closed-set comparison and validated on their own: an
  # absent optional key keeps an existing profile valid byte for byte.
  @optional_options ~w(tool_descriptions)

  @doc "The closed portable tool vocabulary; hosts may supply other tools separately."
  @spec tool_names() :: [String.t()]
  def tool_names, do: Enum.sort(["extension_workflow" | Map.keys(@tools)])

  @doc "Selects quota-backed execution with an explicit session-wide request bound."
  @spec quota(profile :: map(), maximum_requests :: pos_integer()) :: map()
  def quota(profile, maximum_requests)
      when is_integer(maximum_requests) and maximum_requests > 0 do
    update_in(profile, ["options"], fn options ->
      Map.merge(options, %{
        "usage_mode" => "quota",
        "max_requests" => maximum_requests,
        "max_cost_usd" => nil
      })
    end)
  end

  @doc "Reads and validates a profile without constructing a provider."
  @spec read(path :: Path.t(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  def read(path, opts \\ []) do
    with {:ok, bytes} <- File.read(path),
         {:ok, profile} <- JSON.decode(bytes),
         :ok <- validate(profile, opts),
         do: {:ok, profile}
  end

  @doc "Validates the complete portable session profile."
  @spec validate(profile :: term(), opts :: keyword()) :: :ok | {:error, term()}
  def validate(profile, opts \\ [])

  def validate(
        %{"execution" => "live", "model" => model, "tools" => tools, "options" => options} =
          profile,
        opts
      )
      when is_binary(model) and model != "" and is_list(tools) and is_map(options) do
    with {:ok, registry} <- registry(opts) do
      if valid_profile?(profile, registry), do: :ok, else: {:error, :invalid_session_profile}
    end
  end

  def validate(_profile, _opts), do: {:error, :invalid_session_profile}

  @doc """
  Validates the profile and resolves its tools against the registry, without
  model calls.

  Options: `:profile` (required), `:provider` (the host's; the profile's
  effort must be one it advertises for the model, and the workflow tool is
  built over it; defaults to a direct `Lemieux.Providers.ReqLLM`),
  `:tool_registry` and `:name`, the designation the snapshot records.
  """
  @impl Lemieux.Extension
  @spec init(opts :: keyword()) :: {:ok, state()} | {:error, term()}
  def init(opts) do
    profile = Keyword.fetch!(opts, :profile)
    provider = Keyword.get_lazy(opts, :provider, &ReqLLM.new/0)

    with :ok <- validate(profile, opts),
         {:ok, registry} <- registry(opts),
         :ok <- effort(profile, provider) do
      {:ok, %{profile: profile, provider: provider, registry: registry, name: opts[:name]}}
    end
  end

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, %{profile: profile} = state) do
    options = profile["options"]

    %{
      harness
      | system: options["system"],
        tools: tools(state),
        max_turns: options["max_turns"],
        max_cost_usd: options["max_cost_usd"],
        max_requests: options["max_requests"],
        reasoning_effort: options["reasoning_effort"],
        params: [max_tokens: options["max_tokens"], temperature: options["temperature"]]
    }
    |> Harness.append_host_tools(host_tools(state))
    |> Harness.update_harness_context(fn context ->
      extensions = Map.get(context, "extensions", %{})
      Map.put(context, "extensions", Map.put(extensions, "session_profile", provenance(state)))
    end)
  end

  @impl Lemieux.Extension
  def describe(state), do: provenance(state)

  @doc """
  The model the profile names. Host authority, so `apply/2` leaves it off the
  harness and a host passes it with the provider — the model is where the
  tuning runs, not part of the tuning.
  """
  @spec model(state_or_profile :: state() | map()) :: String.t()
  def model(%{profile: %{"model" => model}}), do: model
  def model(%{"model" => model}), do: model

  @doc """
  Resolves the exact session settings using the host's provider, without
  model calls: `apply/2` over an empty harness, plus the model.
  """
  @spec session_options(profile :: map(), provider :: Provider.t(), opts :: keyword()) ::
          {:ok, keyword()} | {:error, term()}
  def session_options(profile, provider, opts \\ []) do
    registry = Keyword.take(opts, [:tool_registry])

    with {:ok, state} <- init([profile: profile, provider: provider] ++ registry) do
      {:ok, [{:model, model(state)} | Harness.new() |> apply(state) |> Harness.session_options()]}
    end
  end

  defp tools(%{profile: profile, registry: registry}) do
    catalog = Map.merge(@tools, registry)
    descriptions = Map.get(profile["options"], "tool_descriptions", %{})

    profile["tools"]
    |> Enum.reject(&(&1 in @host_tools))
    |> Enum.map(&Map.fetch!(catalog, &1))
    |> describe_tools(descriptions)
  end

  defp host_tools(%{profile: profile, provider: provider}) do
    if "extension_workflow" in profile["tools"], do: [Workflow.new(provider)], else: []
  end

  defp provenance(%{profile: profile, name: name}) do
    kind = if "extension_workflow" in profile["tools"], do: "builder", else: "session_extension"
    record = %{"profile_sha256" => Contract.digest(profile), "kind" => kind}
    if is_binary(name), do: Map.put(record, "name", name), else: record
  end

  @doc """
  Builds ordinary agent options; runtime seams are supplied afresh by each host.

  `:provider` is the host's: `lmx` passes `Lemieux.CLI.Runtime.provider/0`,
  the connection its environment and personal configuration imply. A caller
  that names none gets a direct `Lemieux.Providers.ReqLLM` connection, which
  is what that host resolves to when nothing routes elsewhere. A profile
  never reads the environment itself; which route a machine is set up for is
  not tuning.
  """
  @spec configure(profile :: map(), opts :: keyword()) ::
          {:ok, keyword(), map()} | {:error, term()}
  def configure(profile, opts \\ []) do
    provider = Keyword.get_lazy(opts, :provider, &ReqLLM.new/0)

    with {:ok, session} <- session_options(profile, provider, opts) do
      runtime =
        Keyword.take(opts, [:store, :sessions_dir, :supervisor, :detach_runtime, :timeout_ms])

      session =
        Keyword.merge(
          session,
          Keyword.take(opts, [
            :hooks,
            :environment,
            :tool_profile,
            :tool_timeout_ms,
            :tool_output_bytes
          ])
        )

      {:ok, runtime ++ [provider: provider, model: profile["model"], session_options: session],
       profile}
    end
  end

  @doc """
  Returns the profile pointed at `model`, with its budget shape normalized
  for that model, and the list of fields changed.

  Options: `:usage_mode` (`"metered"` or `"quota"`; default the profile's own),
  `:max_cost_usd` (per-session cap for a metered target; default the
  profile's, or 0.25 when converting from quota), `:max_requests` (bound for
  a quota target; default the profile's, or 24 when converting from metered).

  A discovered candidate is a document about instructions and tool text, not
  about one vendor's billing. Confirming it on another model, or evaluating
  it on several, means changing exactly the model and the budget shape and
  nothing else, identically for every arm, and saying so. This is that one
  place, so the confirmation lane and the multi-model evaluator cannot drift.
  """
  @spec retarget(profile :: map(), model :: String.t(), opts :: keyword()) ::
          {map(), [String.t()]}
  def retarget(%{"options" => options} = profile, model, opts \\ [])
      when is_binary(model) and is_list(opts) do
    current = usage_mode(options)
    target = Keyword.get(opts, :usage_mode, current)
    {options, changes} = rebudget(current, target, options, opts)
    changes = if model != profile["model"], do: ["model" | changes], else: changes
    {%{profile | "model" => model, "options" => options}, changes}
  end

  @doc "Runs the same configured session through the normal agent boundary."
  @spec run(input :: Lemieux.Agent.input(), opts :: keyword()) :: Lemieux.Agent.result()
  def run(input, opts), do: Session.run(input, opts)

  defp usage_mode(%{"usage_mode" => "quota"}), do: "quota"
  defp usage_mode(_options), do: "metered"

  # One clause per (current, target) budget shape; the changes list names
  # exactly what moved so the confirmation record can say so.
  defp rebudget("quota", "metered", options, opts) do
    {options
     |> Map.drop(["usage_mode", "max_requests"])
     |> Map.put("max_cost_usd", Keyword.get(opts, :max_cost_usd, 0.25)), ["quota_to_metered"]}
  end

  defp rebudget("metered", "quota", options, opts) do
    {Map.merge(options, %{
       "usage_mode" => "quota",
       "max_requests" => Keyword.get(opts, :max_requests, 24),
       "max_cost_usd" => nil
     }), ["metered_to_quota"]}
  end

  defp rebudget("metered", "metered", options, opts),
    do: rebound(options, "max_cost_usd", Keyword.fetch(opts, :max_cost_usd))

  defp rebudget("quota", "quota", options, opts),
    do: rebound(options, "max_requests", Keyword.fetch(opts, :max_requests))

  defp rebound(options, key, {:ok, value}), do: {Map.put(options, key, value), [key]}
  defp rebound(options, _key, :error), do: {options, []}

  defp effort(profile, provider) do
    effort = profile["options"]["reasoning_effort"]

    if effort == "default" or effort in Provider.reasoning_efforts(provider, profile["model"]),
      do: :ok,
      else: {:error, :profile_effort_not_supported}
  end

  # Names in JSON select trusted, already compiled code. Never resolve module
  # names or load source from a profile; an unknown name remains an error.
  defp registry(opts), do: validate_registry(Keyword.get(opts, :tool_registry, []))

  defp validate_registry(tools) when is_list(tools) do
    with :ok <- Tool.validate_all(tools) do
      names = Enum.map(tools, &Tool.name/1)

      if Enum.any?(names, &(&1 in tool_names() or &1 == "ask_user")),
        do: {:error, :reserved_profile_tool_name},
        else: {:ok, Map.new(Enum.zip(names, tools))}
    end
  end

  defp validate_registry(_tools), do: {:error, :invalid_tool_registry}

  defp valid_profile?(
         %{"model" => model, "tools" => tools, "options" => options} = profile,
         registry
       ) do
    map_size(profile) == 4 and valid_budget?(Map.drop(options, @optional_options)) and
      match?({:ok, _}, Lemieux.ModelSpec.split(model)) and valid_tools?(tools, registry) and
      valid_tool_descriptions?(options, tools) and valid_options?(options)
  end

  # Budget keys are checked by `valid_budget?/1` and descriptions by
  # `valid_tool_descriptions?/2`; everything left must be a known option.
  defp valid_options?(options) do
    options
    |> Map.drop(~w(usage_mode max_requests max_cost_usd) ++ @optional_options)
    |> Enum.all?(&option?/1)
  end

  defp valid_tools?(tools, registry) do
    Enum.uniq(tools) == tools and
      Enum.all?(tools, &(&1 in tool_names() or Map.has_key?(registry, &1)))
  end

  # A description may only name a tool this profile lists, so a stale entry
  # for a tool that was removed fails loudly instead of being carried along.
  defp valid_tool_descriptions?(%{"tool_descriptions" => descriptions}, tools) do
    is_map(descriptions) and
      Enum.all?(descriptions, fn {name, description} ->
        name in tools and name not in @host_tools and is_binary(description) and
          String.trim(description) != ""
      end)
  end

  defp valid_tool_descriptions?(_options, _tools), do: true

  # Validation has already accepted every described name as a listed, non-host
  # tool with non-empty text, so `Tool.decorate/2` raising on a name — or
  # `new!/2` on a description — is a bug in that validation rather than a
  # profile problem.
  defp describe_tools(tools, descriptions) when map_size(descriptions) == 0, do: tools

  defp describe_tools(tools, descriptions) do
    Tool.decorate(
      tools,
      Map.new(descriptions, fn {name, description} ->
        {name, &Override.new!(&1, description: description)}
      end)
    )
  end

  defp valid_budget?(
         %{"usage_mode" => "quota", "max_cost_usd" => nil, "max_requests" => maximum} = options
       ) do
    Enum.sort(Map.keys(options)) == Enum.sort(@options ++ ~w(usage_mode max_requests)) and
      is_integer(maximum) and maximum > 0
  end

  defp valid_budget?(options) do
    Enum.sort(Map.keys(options)) == Enum.sort(@options) and
      option?({"max_cost_usd", options["max_cost_usd"]})
  end

  defp option?({key, value}) when key in ["system", "reasoning_effort"],
    do: is_binary(value) and value != ""

  defp option?({key, value}) when key in ["max_turns", "max_tokens"],
    do: is_integer(value) and value > 0

  defp option?({"max_cost_usd", value}), do: is_number(value) and value > 0
  defp option?({"temperature", value}), do: is_number(value) and value >= 0 and value <= 2
  defp option?(_entry), do: false
end
