defmodule Lemieux.CLI.Diagnostics do
  @moduledoc false
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Extensions
  alias Lemieux.CLI.Logs
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.ProviderMux
  alias Lemieux.Extensions.Permissions
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.ModelSpec
  alias Lemieux.Providers.ReqLLM, as: ReqLLMProvider

  @spec report(options :: Lemieux.CLI.Options.t(), prepared :: map()) :: map()
  def report(options, prepared) do
    %{
      "versions" => Extensions.versions(),
      "model" => prepared.model,
      "model_source" => Atom.to_string(options.host.model_source),
      "route" => route(options, prepared),
      "credentials" => credentials(options, prepared),
      "configuration" => configuration(options),
      "tui_module_available" => Code.ensure_loaded?(ExRatatui),
      "mcp" => mcp(options, prepared),
      "state_dir" => options.host.state_dir,
      # Where this lmx's log lines go (`Lemieux.CLI.Logs`), so the place to
      # look after a sentence that was not enough is in the report people
      # are told to attach.
      "log_file" => Logs.file(),
      "permissions" => permissions(Map.get(prepared, :permissions)),
      "sandbox" => Map.get(prepared, :sandbox),
      "checkpoints" => Map.get(prepared, :checkpoints),
      "subprocess_credentials" => subprocess_credentials(prepared.harness.environment),
      "notices" => prepared.harness.notices,
      "terminal" => terminal()
    }
  end

  # What decides colour on the screen, for a report about a screen that
  # opened without any: an inherited `NO_COLOR` looks exactly like a terminal
  # that cannot draw colour (issue #4). `NO_COLOR` is reported by presence,
  # since any non-empty value means the same; `TERM` and `COLORTERM` are
  # reported as they are, because their values are what a reader needs.
  defp terminal do
    %{
      "term" => System.get_env("TERM"),
      "colorterm" => System.get_env("COLORTERM"),
      "no_color" => if(System.get_env("NO_COLOR") in [nil, ""], do: "unset", else: "set")
    }
  end

  # The file the servers came from — the named one, or the repository's own —
  # and whether the repository's are still waiting for somebody to trust them.
  defp mcp(options, prepared) do
    cwd = Keyword.get_lazy(prepared.options, :cwd, &File.cwd!/0)

    project =
      if is_nil(options.mcp_config),
        do: Discovery.project_mcp_config(cwd)

    report = %{"file" => options.mcp_config || project, "servers" => servers(prepared.harness)}

    case Map.get(prepared, :mcp_trust) do
      %{status: status, servers: held} ->
        Map.merge(report, %{
          "trust" => Atom.to_string(status),
          "held" => Enum.map(held, & &1["name"])
        })

      nil ->
        report
    end
  end

  defp permissions(nil), do: %{"mode" => "off"}

  defp permissions(handle) do
    mode = Permissions.mode(handle)
    %{"mode" => Atom.to_string(mode), "store" => handle.store}
  end

  # Names, never values: which variables commands are allowed to keep.
  defp subprocess_credentials(environment) do
    case Lemieux.Environment.credentials(environment) do
      :inherit -> %{"scrubbed" => false}
      {:scrub, allow} -> %{"scrubbed" => true, "allow" => allow}
    end
  end

  defp servers(harness), do: Enum.map(harness.mcp_servers || [], & &1["name"])
  # The route the start model is on: Ixway, a `--router NAME` route, or one
  # the model's own name selects among the registered ones; else the gateway
  # a base URL points at, else direct.
  defp route(%{ixway: endpoint}, _prepared) when is_binary(endpoint), do: "ixway"
  defp route(%{host: %{route: name}}, _prepared) when is_binary(name), do: name
  defp route(%{base_url: url}, _prepared) when is_binary(url), do: "provider_compatible_gateway"

  defp route(_options, %{model: model} = prepared) do
    name = ModelSpec.provider(model)
    if name in Map.get(prepared, :routes, []), do: name, else: "direct"
  end

  # Only names and presence are returned. URLs, configuration values, headers
  # and key lookup errors may contain secrets and do not belong in diagnostics.
  #
  # Read as `Lemieux.CLI.Options` and `Lemieux.CLI.Limits` read them
  # (`Options.env/1`), so a blank variable is the unset one they treat it
  # as. Read with `System.get_env/1`, a blank `LMX_MAX_TURNS` was listed as
  # set although no limit came from it, and a blank `LMX_CONFIG` was
  # reported as the file `""`.
  @environment ~w(LMX_MODEL LMX_ROUTER LMX_BASE_URL LMX_IXWAY_URL
                  LMX_MAX_TURNS LMX_MAX_REQUESTS LMX_MAX_COST_USD)

  defp configuration(options) do
    %{
      "file" => options.given[:config] || Options.env("LMX_CONFIG") || Config.default_path(),
      "flags" => options.given |> Keyword.keys() |> Enum.map(&to_string/1) |> Enum.uniq(),
      "environment" => Enum.filter(@environment, &Options.env/1),
      "file_fields" => Map.keys((options.config && options.config.settings) || %{}) |> Enum.sort()
    }
  end

  defp credentials(%{ixway: endpoint} = options, _prepared) when is_binary(endpoint) do
    key = System.get_env("IXWAY_API_KEY") || Config.get(options.config, "ixway", %{})["api_key"]
    %{"status" => presence(key), "environment_variable" => "IXWAY_API_KEY"}
  end

  # The connection the model's requests go to: a registered route keeps its
  # own credential (`Lemieux.Provider.Route`), and only names are reported.
  defp credentials(options, %{options: runtime, model: model}) do
    case runtime |> Keyword.fetch!(:provider) |> connection(model) do
      {Lemieux.Providers.ReqLLM, _state} = provider ->
        case ReqLLMProvider.route(provider) do
          nil ->
            provider_credentials(options, ModelSpec.provider(model))

          {module, _state} ->
            %{
              "status" => "route_managed",
              "route" => ModelSpec.provider(model),
              "module" => inspect(module)
            }
        end

      _host_provider ->
        %{"status" => "host_managed"}
    end
  end

  defp connection({ProviderMux, _state} = provider, model), do: ProviderMux.child(provider, model)
  defp connection(provider, _model), do: provider

  defp provider_credentials(options, name) do
    # Transport aliases use the same credential identity as the provider path.
    credential_name = if name == "ollama_cloud", do: "ollama", else: name

    case Enum.find(ReqLLM.Providers.list(), &(Atom.to_string(&1) == credential_name)) do
      nil -> %{"status" => "unknown_provider"}
      provider -> known_provider_credentials(options, name, provider)
    end
  end

  defp known_provider_credentials(options, name, provider) do
    {:ok, module} = ReqLLM.provider(provider)

    if function_exported?(module, :default_env_key, 0) or name == "ollama_cloud" do
      env = ReqLLM.Keys.env_var_name(provider)

      ambient =
        Application.get_env(:req_llm, ReqLLM.Keys.config_key(provider)) || System.get_env(env)

      saved = Config.api_keys(options.config)[name]

      %{
        "status" => presence(ambient || saved),
        "environment_variable" => env,
        "source" => if(is_nil(ambient), do: "personal_config", else: "environment_or_application")
      }
    else
      %{"status" => "not_required"}
    end
  end

  defp presence(value) when is_binary(value) and value != "", do: "present_not_verified"
  defp presence(_value), do: "missing"
end
