defmodule Lemieux.CLI.Runtime.Evaluation.Fingerprint do
  @moduledoc false
  alias Lemieux.CLI.Config
  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Extensions.Permissions
  alias Lemieux.Harness
  alias Lemieux.Harness.Safe
  alias Lemieux.Prompt
  alias Lemieux.Session.Recovery
  alias Lemieux.Store
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tools

  @spec build(prepared :: map(), options :: Lemieux.CLI.Options.t(), host :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def build(prepared, options, host) do
    with {:ok, history} <- history(prepared) do
      harness = prepared.harness
      context = harness.harness_context || %{}

      fields = Harness.session_fields() -- [:system, :tools, :host_tools]
      configuration = Map.new(fields, &{to_string(&1), opaque(Map.fetch!(harness, &1))})
      explanation = Harness.explain(harness)
      code = code()

      freeze = %{
        "schema_version" => 1,
        "system" => system(harness.system),
        "catalog" =>
          Enum.map(
            (harness.tools || Tools.default()) ++ (harness.host_tools || []),
            &descriptor/1
          ),
        "catalog_policy" => Map.take(explanation, ~w(tools disabled_tools)),
        "applied_extensions" => harness.applied,
        "disabled_extensions" => Config.get(options.config, "disabled_extensions", []),
        "resolved_assets" => Map.get(context, "resolved_assets", []),
        "workspace_notices" => harness.notices,
        "model" => prepared.model,
        "provider_identity" => host[:provider_identity],
        "generation" => %{
          "params" => Safe.request_params(harness.params || []),
          "reasoning_effort" => Contract.json(harness.reasoning_effort)
        },
        "retry_policy" => retry(harness.provider_retry),
        "verification" => Config.get(options.config, "verify", true),
        "environment" => %{
          "module" => environment_name(harness.environment),
          "state_sha256" => opaque(harness.environment)
        },
        "cwd" => host[:cwd] || File.cwd!(),
        "history" => history,
        "session_configuration" => configuration,
        "cacheable" =>
          not is_nil(host[:provider_identity]) and complete_code?(code) and
            not volatile?(identity(Map.take(harness, Harness.session_fields()))),
        "strategy_code" =>
          Map.new([:environment, :messages, :guard, :compaction], fn field ->
            {to_string(field), strategy_code(Map.fetch!(harness, field))}
          end),
        "host_constraints_sha256" =>
          opaque(Keyword.take(prepared.options, Harness.session_fields())),
        "host_config_sha256" => opaque(host_config(options)),
        "code" => code
      }

      {:ok, Map.put(freeze, "sha256", Contract.digest(freeze))}
    end
  end

  defp retry(nil), do: retry([])
  defp retry(false), do: %{"enabled" => false}

  defp retry(settings),
    do:
      settings
      |> Recovery.retry_policy()
      |> Map.drop([:classify])
      |> Contract.json()
      |> Map.put("enabled", true)

  defp host_config(%{config: nil}), do: %{}
  defp host_config(%{config: config}), do: config.settings

  defp system(:default), do: Prompt.default()
  defp system(system), do: system
  defp descriptor(tool), do: tool |> Tool.descriptor() |> Descriptor.to_map()

  defp history(%{resume: nil}), do: {:ok, nil}

  defp history(%{resume: id, options: options}) do
    with {:ok, entries} <- Store.read(Keyword.fetch!(options, :store), id) do
      bytes = Enum.map(entries, &Entry.encode!/1)

      {:ok,
       %{"session_id" => id, "entries" => length(entries), "sha256" => Contract.sha256(bytes)}}
    end
  end

  defp environment_name({module, _private}), do: inspect(module)
  defp environment_name(nil), do: "session_default"
  defp environment_name(module) when is_atom(module), do: inspect(module)

  # A one-way comparison identity, never an encoding that is saved or decoded.
  # Captured closure state matters: module/name alone misses policy changes.
  defp opaque(value),
    do: value |> identity() |> :erlang.term_to_binary([:deterministic]) |> Contract.sha256()

  defp identity(%Permissions.Handle{} = handle),
    do: {:permission_policy, Permissions.mode(handle), Permissions.remembered(handle)}

  defp identity(%module{} = value), do: {module, identity(Map.from_struct(value))}

  defp identity(value) when is_function(value) do
    metadata = Map.new(:erlang.fun_info(value))

    {:callback, metadata.module, metadata.name, metadata.arity, metadata[:new_uniq],
     module_identity(metadata.module), identity(metadata.env)}
  end

  defp identity(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, identity(item)} end)

  defp identity(value) when is_list(value), do: Enum.map(value, &identity/1)

  defp identity(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.map(&identity/1) |> List.to_tuple()

  defp identity(value) when is_pid(value) or is_reference(value) or is_port(value),
    do: {:volatile, value}

  defp identity(value), do: value

  defp volatile?({:volatile, _value}), do: true

  defp volatile?(value) when is_map(value),
    do: Enum.any?(value, fn {_key, item} -> volatile?(item) end)

  defp volatile?(value) when is_tuple(value), do: value |> Tuple.to_list() |> volatile?()
  defp volatile?(value) when is_list(value), do: Enum.any?(value, &volatile?/1)
  defp volatile?(_value), do: false

  defp strategy_code({module, _state}), do: module_identity(module)
  defp strategy_code(nil), do: "session_default"
  defp strategy_code(module) when is_atom(module), do: module_identity(module)

  defp code do
    Map.new([:lemieux, :req_llm, :llm_db], fn app ->
      modules = Application.spec(app, :modules) || []
      identities = Map.new(modules, &{inspect(&1), module_identity(&1)})

      {to_string(app),
       %{
         "version" => to_string(Application.spec(app, :vsn)),
         "complete" =>
           modules != [] and
             Enum.all?(identities, fn {_name, digest} -> digest != "unavailable" end),
         "modules_sha256" => Contract.digest(identities)
       }}
    end)
    |> Map.merge(%{"elixir" => System.version(), "otp" => System.otp_release()})
  end

  defp complete_code?(code),
    do: code["lemieux"]["complete"] and code["req_llm"]["complete"] and code["llm_db"]["complete"]

  defp module_identity(module) do
    case :code.which(module) do
      :cover_compiled ->
        file_identity(module, :code.where_is_file(Atom.to_charlist(module) ++ ~c".beam"))

      path ->
        case :code.is_loaded(module) do
          false -> file_identity(module, path)
          _loaded -> loaded_identity(module)
        end
    end
  end

  defp file_identity(module, path) do
    case :beam_lib.md5(path) do
      {:ok, {^module, md5}} -> Base.encode16(md5, case: :lower)
      _missing -> "unavailable"
    end
  end

  defp loaded_identity(module) do
    if function_exported?(module, :module_info, 1),
      do: module.module_info(:md5) |> Base.encode16(case: :lower),
      else: "unavailable"
  end
end
