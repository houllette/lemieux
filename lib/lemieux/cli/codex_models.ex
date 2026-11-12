defmodule Lemieux.CLI.CodexModels do
  @moduledoc """
  Account catalog discovery for ReqLLM's existing Codex backend transport.

  This is host discovery, not an inference adapter. The public Sign in with
  ChatGPT catalog has a different endpoint/token contract; tokens borrowed for
  ReqLLM's Codex backend must stay on that backend. App-server `model/list`
  can be bundled or cached and is not an account entitlement catalog.

  Credential resolution mirrors the CLI decorator and ReqLLM's explicit-auth
  precedence, but only reads access credentials. Discovery never refreshes or
  rewrites either owner's OAuth file. Cache identities include the source,
  token, account and destination; only their digest survives in cache state.
  """
  alias Lemieux.CLI.{CodexProvider, Config, Options}
  alias Lemieux.CLI.Learning.CodexAuth
  alias ReqLLM.Providers.OpenAICodex

  defmodule Connection do
    @moduledoc false
    @derive {Inspect, only: []}
    defstruct [:token, :account_id, :scope, :expires_at]

    @type t :: %__MODULE__{
            token: String.t(),
            account_id: String.t(),
            scope: binary(),
            expires_at: integer() | nil
          }
  end

  @url "https://chatgpt.com/backend-api/codex/models"
  # Catalog protocol version verified for the existing ReqLLM backend route.
  # This describes the request contract, not the installed Codex executable.
  @client_version "0.167.2"
  @max_file_bytes 1_048_576

  @doc "Resolves the active inference account read-only; never includes credentials in an error."
  @spec connection(options :: Options.t(), opts :: keyword()) ::
          {:ok, Connection.t()} | :unconfigured | {:error, atom()}
  def connection(options, opts \\ []) do
    params = Keyword.get(opts, :params, [])

    with {:ok, access, account, expires, source} <- credential(options, params, opts),
         :ok <- valid(access, account, expires),
         :ok <- route(options, params) do
      {:ok,
       %Connection{
         token: access,
         account_id: account,
         expires_at: expires,
         scope: :crypto.hash(:sha256, :erlang.term_to_binary({source, access, account, @url}))
       }}
    end
  end

  # The destination is selected exactly as ReqLLM selects it. Unknown custom
  # routes remain usable for inference; discovery must not send their token to
  # an unrelated official endpoint or guess a private server's catalog path.
  defp route(options, params) do
    spec =
      if String.starts_with?(options.model, "openai_codex:"),
        do: options.model,
        else: "openai_codex:gpt-6-sol"

    {:ok, model} = ReqLLM.model(spec)

    params =
      if options.base_url, do: Keyword.put_new(params, :base_url, options.base_url), else: params

    base = ReqLLM.Provider.Options.effective_base_url(OpenAICodex, model, params)

    if String.trim_trailing(base, "/") in [
         "https://chatgpt.com/backend-api",
         "https://chatgpt.com/backend-api/codex",
         "https://chatgpt.com/backend-api/codex/responses"
       ], do: :ok, else: {:error, :unsupported_route}
  end

  defp credential(options, params, opts) do
    nested = nested(params)
    access = Keyword.get(params, :access_token) || Keyword.get(nested, :access_token)

    cond do
      is_binary(access) ->
        {:ok, access, account(params, nested, access), jwt_expiry(access), :option}

      not CodexProvider.local_auth?(params) ->
        from_file(params, nested)

      Config.personal?(options.config) ->
        from_local(params, nested, opts)

      true ->
        :unconfigured
    end
  end

  defp from_local(params, nested, opts) do
    source =
      Keyword.get_lazy(opts, :source, fn ->
        Path.join(
          System.get_env("CODEX_HOME") || Path.join(System.user_home!(), ".codex"),
          "auth.json"
        )
      end)

    case CodexAuth.credential(source: source) do
      {:ok, value} ->
        {:ok, value.access,
         Keyword.get(params, :chatgpt_account_id) || Keyword.get(nested, :chatgpt_account_id) ||
           value.account_id, DateTime.to_unix(value.expires_at, :millisecond),
         {:native, Path.expand(source)}}

      {:error, {:codex_not_signed_in, _}} ->
        :unconfigured

      {:error, _} ->
        {:error, :credentials}
    end
  end

  defp from_file(params, nested) do
    path =
      Enum.find(
        [
          params[:oauth_file],
          nested[:oauth_file],
          params[:auth_file],
          nested[:auth_file],
          Application.get_env(:req_llm, :oauth_file),
          Application.get_env(:req_llm, :auth_file),
          System.get_env("REQ_LLM_OAUTH_FILE"),
          System.get_env("REQ_LLM_AUTH_FILE")
        ],
        &(is_binary(&1) and String.trim(&1) != "")
      )

    with true <- is_binary(path),
         path = Path.expand(path),
         {:ok, %{size: size, type: :regular}} when size <= @max_file_bytes <- File.stat(path),
         {:ok, body} when byte_size(body) <= @max_file_bytes <- File.read(path),
         {:ok, payload} when is_map(payload) <- JSON.decode(body),
         entry when is_map(entry) <- payload["openai-codex"] || payload["openai_codex"],
         access when is_binary(access) <- entry["access"] || entry["access_token"] do
      expires =
        [expiry(entry["expires"] || entry["expires_at"]), jwt_expiry(access)]
        |> Enum.reject(&is_nil/1)
        |> Enum.min(fn -> nil end)

      chosen =
        params[:chatgpt_account_id] || nested[:chatgpt_account_id] || entry["accountId"] ||
          entry["account_id"] || OpenAICodex.account_id_from_token(access)

      {:ok, access, chosen, expires, {:oauth_file, path}}
    else
      _ -> {:error, :credentials}
    end
  end

  defp nested(params) do
    all = Keyword.get(params, :provider_options, [])
    Keyword.merge(Keyword.delete(all, :openai_codex), Keyword.get(all, :openai_codex, []))
  end

  defp account(params, nested, access),
    do:
      params[:chatgpt_account_id] || nested[:chatgpt_account_id] ||
        OpenAICodex.account_id_from_token(access)

  defp jwt_expiry(access) do
    with [_header, payload, _signature] <- String.split(access, "."),
         {:ok, body} <- Base.url_decode64(payload, padding: false),
         {:ok, %{"exp" => exp}} when is_integer(exp) <- JSON.decode(body),
         do: exp * 1000,
         else: (_ -> nil)
  end

  defp expiry(value) when is_integer(value) and value > 0 and value < 10_000_000_000,
    do: value * 1000

  defp expiry(value) when is_integer(value) and value > 0, do: value
  defp expiry(value) when is_float(value) and value > 0, do: expiry(round(value))

  defp expiry(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> expiry(number)
      _ -> nil
    end
  end

  defp expiry(_), do: nil

  defp valid(access, account, expires) do
    cond do
      is_integer(expires) and expires <= System.system_time(:millisecond) -> {:error, :expired}
      access == "" or not is_binary(account) or account == "" -> {:error, :credentials}
      true -> :ok
    end
  end

  @doc "Fetches only the visible server catalog, preserving server order and unknown model IDs."
  @spec fetch(connection :: Connection.t(), opts :: keyword()) ::
          {:ok, [String.t()]} | {:error, atom()}
  def fetch(%Connection{} = connection, opts \\ []) do
    get = Keyword.get(opts, :get, &Req.get/2)

    result =
      get.(@url,
        params: [client_version: @client_version],
        headers: [
          {"authorization", "Bearer " <> connection.token},
          {"chatgpt-account-id", connection.account_id}
        ],
        retry: false,
        redirect: false,
        connect_options: [timeout: 1000],
        receive_timeout: 5000
      )

    catalog(result)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  defp catalog({:ok, %{status: 200, body: %{"models" => models}}}) when is_list(models) do
    specs =
      for %{"visibility" => "list", "slug" => slug} <- models,
          is_binary(slug) and byte_size(slug) in 1..200,
          Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._-]*\z/, slug),
          do: "openai_codex:" <> slug

    {:ok, Enum.uniq(specs)}
  end

  defp catalog({:ok, %{status: 200}}), do: {:error, :invalid_catalog}
  defp catalog({:ok, %{status: status}}) when status in [401, 403], do: {:error, :unauthorized}
  defp catalog(_), do: {:error, :unavailable}

  @doc "Safe discovery notices; raw responses, account IDs and credential paths are never displayed."
  @spec message(reason :: atom()) :: String.t()
  def message(:unsupported_route),
    do:
      "Codex account model discovery is unavailable for this inference route. A model can still be selected manually."

  def message(reason) when reason in [:credentials, :expired, :unauthorized],
    do:
      "Codex account models could not be loaded. Check the sign-in used for inference and renew it with its owner; discovery never refreshes credentials. Your selected model is preserved."

  def message(_),
    do:
      "Codex account models could not be refreshed. Your selected model is preserved; discovery will retry later."
end
