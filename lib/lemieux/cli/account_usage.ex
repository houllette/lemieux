defmodule Lemieux.CLI.AccountUsage do
  @moduledoc """
  Read-only account reporting for configured CLI connections.

  OpenRouter reports key-scoped spend with its inference credential. OpenAI
  and Anthropic require a separately authorized admin reporting key; inference
  credentials are never tried against an administrative endpoint. Codex reports
  subscription windows through its documented app-server account surface with
  externally supplied access tokens, never refresh ownership or an agent turn.
  Unknown routes/providers are listed without contacting them. Reporting uses
  fixed official endpoints, independently of model inference through ReqLLM.
  """
  alias Lemieux.CLI.AccountUsage.Codex
  alias Lemieux.CLI.CodexProvider
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Learning.CodexAuth
  alias Lemieux.Contract
  alias Lemieux.ModelSpec

  @timeout 12_000

  @doc "Fetches configured accounts concurrently with independent bounded failures."
  @spec fetch(options :: map(), opts :: keyword()) :: map()
  def fetch(options, opts \\ []) do
    now = Keyword.get(opts, :now, System.system_time(:second))
    providers = configured(options, opts)

    accounts =
      providers
      |> Task.async_stream(&safe_fetch(&1, options, now, opts),
        timeout: @timeout,
        on_timeout: :kill_task,
        max_concurrency: 4
      )
      |> Enum.zip(providers)
      |> Enum.map(fn
        {{:ok, account}, _provider} ->
          account

        {_timeout, provider} ->
          failed(provider, "Usage report timed out; other accounts are unaffected.")
      end)

    %{fetched_at: now, accounts: accounts}
  end

  defp configured(options, opts) do
    explicit = Config.get(options.config, "providers", %{}) |> Map.keys()
    ambient = if Config.personal?(options.config), do: ambient_providers(opts), else: []

    codex =
      if Config.personal?(options.config) and
           CodexProvider.local_auth?(Keyword.get(opts, :params, [])) and
           match?({:ok, _}, CodexAuth.credential(Keyword.get(opts, :codex_auth, []))),
         do: ["openai_codex"],
         else: []

    routes = Keyword.get(opts, :routes, []) |> Enum.map(&elem(&1, 0))

    selected =
      case Map.get(options, :host, %{}) do
        %{model_source: :fallback} -> []
        _chosen -> [ModelSpec.provider(options.model)]
      end

    (explicit ++ ambient ++ codex ++ routes ++ selected)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp ambient_providers(opts) do
    ReqLLM.Providers.list()
    |> Enum.filter(fn provider ->
      env = getenv(ReqLLM.Keys.env_var_name(provider), opts)
      present?(env) or present?(Application.get_env(:req_llm, ReqLLM.Keys.config_key(provider)))
    end)
    |> Enum.map(&Atom.to_string/1)
  end

  defp safe_fetch(provider, options, now, opts) do
    section = Config.get(options.config, "providers", %{}) |> Map.get(provider, %{})

    account = routed_fetch(provider, section, options, now, opts)

    Map.put(account, :scope_key, scope_key(provider, section, opts))
  rescue
    _error ->
      failed(provider, "Usage reporting failed; no raw response or credentials were retained.")
  catch
    _kind, _reason -> failed(provider, "Usage reporting stopped unexpectedly.")
  end

  defp routed_fetch("openai_codex" = provider, section, options, now, opts) do
    cond do
      not CodexProvider.local_auth?(Keyword.get(opts, :params, [])) ->
        unavailable(
          provider,
          "Custom Codex authentication is in use; no matching account reporter is registered, so local sign-in was not queried."
        )

      Config.personal?(options.config) or Keyword.has_key?(opts, :codex_auth) ->
        fetch_provider(provider, section, now, opts)

      true ->
        unavailable(
          provider,
          "Local Codex sign-in lookup is disabled for this configuration; quota is unknown."
        )
    end
  end

  defp routed_fetch(provider, section, options, now, opts) do
    if options.base_url,
      do:
        unavailable(
          provider,
          "Custom inference endpoint: no account-reporting capability is registered for this route."
        ),
      else: fetch_provider(provider, section, now, opts)
  end

  # Cached results must never migrate across a key/account/project change.
  # This opaque equality key is not displayed or written into a transcript.
  defp scope_key("openai_codex", _section, _opts), do: nil

  defp scope_key(provider, section, opts) do
    env_names = [
      String.upcase(provider) <> "_API_KEY",
      String.upcase(provider) <> "_ADMIN_KEY",
      section["usage_api_key_env"]
    ]

    ambient = env_names |> Enum.reject(&is_nil/1) |> Enum.map(&getenv(&1, opts))

    app_key =
      case provider do
        "openai" -> Application.get_env(:req_llm, :openai_api_key)
        "anthropic" -> Application.get_env(:req_llm, :anthropic_api_key)
        "openrouter" -> Application.get_env(:req_llm, :openrouter_api_key)
        _other -> nil
      end

    Contract.sha256(JSON.encode!([provider, section, ambient, app_key]))
  end

  defp fetch_provider("openai_codex" = provider, _section, now, opts) do
    case Codex.fetch(opts) do
      {:ok, windows} ->
        success(provider, "signed-in ChatGPT account · subscription quota", windows, now)

      {:error, message} ->
        failed(provider, message)
    end
  end

  defp fetch_provider("openrouter" = provider, section, now, opts) do
    with key when is_binary(key) <- inference_key(:openrouter, section, opts),
         {:ok, body} <-
           get(
             "https://openrouter.ai/api/v1/key",
             [{"authorization", "Bearer " <> key}],
             [],
             opts
           ),
         %{"data" => data} when is_map(data) <- body do
      windows =
        Enum.map(
          [{"daily", "usage_daily"}, {"weekly", "usage_weekly"}, {"monthly", "usage_monthly"}],
          fn {label, field} ->
            window("provider #{label} window", "USD", number(data[field]), nil)
          end
        )

      allowance =
        window(
          "key allowance (reset #{safe_reset(data["limit_reset"])})",
          "USD",
          number(data["usage"]),
          number(data["limit_remaining"])
        )

      success(
        provider,
        "current API key · excludes other keys/accounts",
        windows ++ [allowance],
        now
      )
    else
      nil -> unavailable(provider, "No usable inference credential is configured.")
      {:error, message} -> failed(provider, message)
      _invalid -> failed(provider, "Provider returned an unrecognized usage report.")
    end
  end

  defp fetch_provider(provider, section, now, opts) when provider in ["openai", "anthropic"] do
    key =
      section["usage_api_key"] ||
        getenv(section["usage_api_key_env"] || String.upcase(provider) <> "_ADMIN_KEY", opts)

    if present?(key) do
      fetch_costs(provider, key, section, now, opts)
    else
      unavailable(
        provider,
        "Organization spend requires a separately authorized admin reporting key (providers.#{provider}.usage_api_key_env). Inference keys do not grant billing access."
      )
    end
  end

  defp fetch_provider(provider, _section, _now, _opts),
    do:
      unavailable(
        provider,
        "No account-reporting capability is available for this provider/route. Check its account dashboard."
      )

  defp fetch_costs(provider, key, section, now, opts) do
    {:ok, at} = DateTime.from_unix(now)
    first = DateTime.new!(Date.new!(at.year, at.month, 1), ~T[00:00:00]) |> DateTime.to_unix()
    {url, headers, params} = costs_request(provider, key, section, first, now)

    with {:ok, body} <- get(url, headers, params, opts),
         {:ok, amount, unit} <- costs(provider, body) do
      report = %{window("month to date (UTC)", unit, amount, nil) | start_at: first, end_at: now}
      scope = if section["usage_project_id"], do: "selected project", else: "organization"
      account = success(provider, scope <> " · provider-reported cost", [report], now)

      if provider == "anthropic",
        do: %{
          account
          | message:
              "Priority Tier costs are excluded by the provider's cost endpoint; this is not a full invoice."
        },
        else: account
    else
      {:error, message} -> failed(provider, message)
    end
  end

  defp costs_request("openai", key, section, first, now) do
    params = [start_time: first, end_time: now, bucket_width: "1d", limit: 31]

    params =
      if section["usage_project_id"],
        do: params ++ [{"project_ids[]", section["usage_project_id"]}],
        else: params

    {"https://api.openai.com/v1/organization/costs", [{"authorization", "Bearer " <> key}],
     params}
  end

  defp costs_request("anthropic", key, _section, first, now) do
    params = [
      starting_at: DateTime.from_unix!(first) |> DateTime.to_iso8601(),
      ending_at: DateTime.from_unix!(now) |> DateTime.to_iso8601(),
      limit: 31
    ]

    {"https://api.anthropic.com/v1/organizations/cost_report",
     [{"x-api-key", key}, {"anthropic-version", "2023-06-01"}], params}
  end

  defp costs(_provider, %{"has_more" => true}),
    do:
      {:error,
       "Reporting window is incomplete (more pages available); no partial total is shown."}

  defp costs(provider, %{"data" => buckets, "has_more" => false}) when is_list(buckets) do
    parsed = Enum.flat_map(buckets, &bucket_costs(provider, &1))

    if Enum.all?(parsed, &is_number/1),
      do: {:ok, Enum.sum(parsed), "USD"},
      else: {:error, "Provider reported unknown cost fields or currency; no total was inferred."}
  end

  defp costs(_provider, _body), do: {:error, "Provider returned an unrecognized cost report."}

  defp bucket_costs(provider, %{"results" => results}) when is_list(results),
    do: Enum.map(results, &cost_amount(provider, &1))

  defp bucket_costs(_provider, _invalid), do: [nil]

  defp cost_amount("openai", %{"amount" => %{"value" => value, "currency" => "usd"}}),
    do: number(value)

  defp cost_amount("anthropic", %{"amount" => value, "currency" => "USD"}), do: cents(value)
  defp cost_amount(_provider, _value), do: nil

  defp cents(value) when is_binary(value) do
    case Float.parse(value) do
      {amount, ""} when amount >= 0 -> amount / 100
      _invalid -> nil
    end
  end

  defp cents(_value), do: nil

  defp get(url, headers, params, opts) do
    request = Keyword.get(opts, :request, &Req.get/1)

    case request.(
           url: url,
           headers: headers,
           params: params,
           receive_timeout: 5_000,
           connect_options: [timeout: 5_000],
           retry: false,
           redirect: false
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: status}} when status in [401, 403] ->
        {:error, "Usage reporting is not authorized by the current reporting credential/scope."}

      {:ok, %{status: 429}} ->
        {:error, "Usage reporting was rate limited; refresh later."}

      _failure ->
        {:error, "Usage reporting is unavailable; no raw response was retained."}
    end
  end

  defp inference_key(atom, section, opts) do
    Application.get_env(:req_llm, ReqLLM.Keys.config_key(atom)) ||
      getenv(ReqLLM.Keys.env_var_name(atom), opts) || section["api_key"]
  end

  defp getenv(name, opts), do: Keyword.get(opts, :getenv, &System.get_env/1).(name)
  defp present?(value), do: is_binary(value) and String.trim(value) != ""
  defp number(value) when is_number(value) and value >= 0, do: value
  defp number(_value), do: nil
  defp safe_reset(value) when value in ["daily", "weekly", "monthly"], do: value
  defp safe_reset(_unknown), do: "unknown"

  @doc false
  @spec window(
          label :: String.t(),
          unit :: String.t(),
          used :: number() | nil,
          remaining :: number() | nil
        ) :: map()
  def window(label, unit, used, remaining),
    do: %{
      label: label,
      unit: unit,
      used: used,
      remaining: remaining,
      start_at: nil,
      end_at: nil,
      reset_at: nil
    }

  defp success(provider, scope, windows, now),
    do: %{
      provider: provider,
      scope: scope,
      status: :ok,
      windows: windows,
      fetched_at: now,
      stale?: false,
      message: nil
    }

  defp unavailable(provider, message),
    do: %{provider: provider, status: :unavailable, message: message}

  defp failed(provider, message), do: %{provider: provider, status: :error, message: message}
end
