defmodule Lemieux.CLI.Errors do
  @moduledoc """
  What `lmx` says when something stops it, and the exit status it says it with.

  Two readers, one vocabulary. A person reads the sentence: it names what
  went wrong in their terms — a key to set, a session open elsewhere, a limit
  reached — and never the advice that cannot help (`/retry` does not conjure
  an API key). A script reads the status, which `lmx run` documents:

  | Status | Meaning |
  | --- | --- |
  | 0 | the answer was produced |
  | 1 | anything else: an unexpected error |
  | 2 | usage: a flag, an argument or the configuration file was wrong |
  | 3 | credentials: no API key, or the provider refused the one given |
  | 4 | a limit stopped the work: requests, spend, turns, or no progress |
  | 5 | the work was cancelled |
  | 6 | the provider failed, after the session's own retries |

  The categories are derived from typed values — the session's stop reason
  and `Lemieux.Provider.Error`'s projection of the provider's failure —
  never from matching the text of a message.
  """

  alias Lemieux.CLI.Models
  alias Lemieux.Conversation
  alias Lemieux.ModelSpec
  alias Lemieux.Provider.Error, as: ProviderError

  @typedoc "Why a command stopped, as a script would branch on it."
  @type category :: :ok | :other | :usage | :auth | :limit | :cancelled | :provider

  @statuses %{ok: 0, other: 1, usage: 2, auth: 3, limit: 4, cancelled: 5, provider: 6}

  @doc "The exit status for `category`; see the module documentation."
  @spec exit_status(category :: category()) :: non_neg_integer()
  def exit_status(category), do: Map.fetch!(@statuses, category)

  @doc """
  The category a finished prompt falls into, from its stop reason and the
  error the turn ended on, if any.
  """
  @spec category(stop_reason :: term(), error :: term()) :: category()
  def category(stop_reason, nil) when stop_reason in [:stop, :end_turn], do: :ok
  def category(:cancelled, _error), do: :cancelled
  def category({:budget, _payload}, _error), do: :limit
  def category(reason, _error) when reason in [:max_turns, :no_progress], do: :limit
  def category(_stop_reason, error) when not is_nil(error), do: error_category(error)
  def category(_stop_reason, _error), do: :other

  @doc "The category of an error term alone."
  @spec error_category(reason :: term()) :: category()
  def error_category({:missing_api_key, _provider, _hint}), do: :auth
  def error_category({:budget, _payload}), do: :limit
  def error_category({:session_locked, _holder}), do: :other
  def error_category({:unknown_model, _spec, _hint}), do: :usage

  def error_category(reason) do
    case ProviderError.http_status(reason) do
      status when status in [401, 403] -> :auth
      status when is_integer(status) -> :provider
      _none -> provider_category(ProviderError.category(reason))
    end
  end

  defp provider_category(category)
       when category in [:rate_limit, :server, :timeout, :context_limit],
       do: :provider

  defp provider_category(_other), do: :other

  @typedoc """
  What a sentence may name beyond the failure itself: the session's `:model`
  and the `:base_url` it was routed through, so a failed connection can say
  where it was going — `nil` when there was no gateway, `:unknown` when the
  caller cannot tell; the `:resume` reference a person typed; the
  `:program` hints are spelled with (`Lemieux.CLI.program/1`); and the
  `:switch` that picks another model where the sentence is read
  (`"--model"` unless the terminal UI says `"/model"`).
  """
  @type context :: [
          model: String.t() | nil,
          base_url: String.t() | :unknown | nil,
          resume: String.t() | nil,
          program: String.t(),
          switch: String.t()
        ]

  # What a connection that never opened says, by the reason the transport
  # gave. A refusal that arrives with a status is not here: the provider
  # answered, and its body says why.
  @unreachable %{
    econnrefused: "connection refused",
    nxdomain: "the host name did not resolve",
    ehostunreach: "no route to the host",
    enetunreach: "the network is unreachable",
    ehostdown: "the host is down",
    enetdown: "the network is down",
    eaddrnotavail: "the address is not available"
  }

  @doc """
  One sentence for `reason`, in a person's terms; `describe/2` without
  context.
  """
  @spec describe(reason :: term()) :: String.t()
  def describe(reason), do: describe(reason, [])

  @doc """
  One sentence for `reason`, in a person's terms, using what `context` knows.

  A transcript held open by another `lmx` names the process, since the fix
  is in somebody's other terminal; a missing key names the variable to set; a
  model specification that does not parse says how to write one; a session
  reference that names nothing says so in words rather than as `:not_found`.
  A connection that never opened names the endpoint and the likely fix when
  `context` has the model — "could not reach ollama at
  http://localhost:11434 (connection refused): is Ollama running?" — where
  it used to say only "connection refused". Everything else is
  `Lemieux.Provider.Error.message/1`.
  """
  @spec describe(reason :: term(), context :: context()) :: String.t()
  def describe({:session_locked, holder}, _context) when is_map(holder), do: locked(holder)

  # Not "save one with /provider in the terminal UI", which this said:
  # `/provider` switches providers and saves no key. The provider panel
  # (`Lemieux.TUI.FirstRun`) does, and it opens whenever the terminal UI
  # starts on a model whose key it cannot find.
  def describe({:missing_api_key, provider, _hint}, _context) do
    "no API key for #{provider}: set #{key_variable(provider)}, or choose another model " <>
      "with --model (the terminal UI asks for a key it cannot find when it starts, and can " <>
      "save it)"
  end

  def describe({:unknown_model, spec, hint}, context),
    do: unknown_model(spec, hint, Keyword.get(context, :program, "lmx"))

  def describe(:not_found, context) do
    program = Keyword.get(context, :program, "lmx")

    case Keyword.get(context, :resume) do
      reference when is_binary(reference) ->
        "no stored session has the id or name #{reference} " <>
          "(#{program} help sessions says where they live)"

      _unknown ->
        "no stored session has that id or name (#{program} help sessions says where they live)"
    end
  end

  def describe({:ambiguous, _ids} = reason, _context), do: Conversation.describe(reason)
  def describe({:unreadable, _id, _why} = reason, _context), do: Conversation.describe(reason)
  def describe(reason, _context) when is_binary(reason), do: reason

  def describe(reason, context),
    do: connection_failure(reason, context) || ProviderError.message(reason)

  @doc """
  The sentence for a connection to the model's provider that never opened —
  `could not reach ollama at http://localhost:11434 (connection refused): is
  Ollama running? …` — or `nil` when `reason` is something else, or
  `context` has no model to name.

  `describe/2` says it for `lmx run`, which knows whether a gateway was in
  the way. The terminal UI's conversation does not, and passes `base_url:
  :unknown`: the sentence then names the provider and the fix but no
  address, because the provider's own address would be the wrong one behind
  `--base-url`.
  """
  @spec connection_failure(reason :: term(), context :: context()) :: String.t() | nil
  def connection_failure(reason, context) do
    case {unreachable(reason), Keyword.get(context, :model)} do
      {why, model} when is_atom(why) and not is_nil(why) and is_binary(model) ->
        unreachable(why, model, context)

      _other ->
        nil
    end
  end

  @doc """
  A sentence for a model specification that could not be resolved, naming the
  fix for the two mistakes people actually make: a bare model name, and a
  provider `req_llm` does not know. `program` is how the help command is
  spelled (`Lemieux.CLI.program/1`), or `nil` for a sentence that names no
  command: the terminal UI's error line, which cannot tell `lmx` from `mix
  lmx` and offers `/model` instead (`Lemieux.Conversation.error_line/2`).
  """
  @spec unknown_model(spec :: String.t(), hint :: term(), program :: String.t() | nil) ::
          String.t()
  def unknown_model(spec, hint, program \\ "lmx")

  def unknown_model(spec, hint, program) when hint in [:invalid_format, :empty_segment],
    do:
      "#{spec} is not a model specification: write PROVIDER:MODEL, for example " <>
        "#{example_model()}" <> if(program, do: " (#{program} help models)", else: "")

  def unknown_model(spec, :unknown_provider, program),
    do:
      "#{spec} names a provider lmx does not know (#{ModelSpec.provider(spec)})" <>
        if(program,
          do:
            "; #{program} help models lists the usual ones, and an extension that registers " <>
              "a model route by that name is selected with --extension NAME or --extension-dir PATH",
          else: ""
        )

  def unknown_model(spec, hint, _program),
    do: "#{spec} is not a model lmx can reach: #{ProviderError.message(hint)}"

  defp example_model do
    Enum.find_value(Models.recommended(), "anthropic:claude-sonnet-5", fn row ->
      row.provider == "anthropic" && row.model
    end)
  end

  # The transport's reason for a connection that never opened, however deep
  # `req_llm` and Finch wrapped it (`%Finch.TransportError{reason:
  # :econnrefused}`, a `cause` around that), or `nil`.
  defp unreachable(reason) when is_atom(reason) and is_map_key(@unreachable, reason), do: reason

  defp unreachable(%{} = reason),
    do: unreachable(Map.get(reason, :reason)) || unreachable(Map.get(reason, :cause))

  defp unreachable(_reason), do: nil

  defp unreachable(why, model, context) do
    provider = ModelSpec.provider(model) || model
    base_url = Keyword.get(context, :base_url)
    switch = Keyword.get(context, :switch, "--model")
    at = with url when is_binary(url) <- endpoint(provider, base_url), do: " at " <> url

    "could not reach #{provider}#{at} (#{Map.fetch!(@unreachable, why)})" <>
      remedy(provider, why, base_url, switch)
  end

  # A refused connection is something not listening: a local daemon not
  # started, or the server a gateway flag names. Anything else is the road
  # there.
  defp remedy("ollama", :econnrefused, base_url, switch) when base_url in [nil, :unknown],
    do:
      ": is Ollama running? Start it with `ollama serve`, or choose another model with " <>
        switch

  defp remedy(_provider, :econnrefused, base_url, _switch) when is_binary(base_url),
    do: ": is the server --base-url points at running?"

  defp remedy(_provider, :econnrefused, :unknown, _switch),
    do: ": is the server it was sent to running?"

  defp remedy(_provider, _why, _base_url, _switch), do: ": are you offline, or behind a proxy?"

  # Where the request was going: the gateway it was routed through, else the
  # provider's configured or default base URL. Only the origin — scheme, host
  # and port — because that is what failed to connect, and because a URL's
  # user part, path or query can carry a token (`Lemieux.CLI.Diagnostics`
  # prints no URL at all for that reason).
  defp endpoint(_provider, base_url) when is_binary(base_url), do: origin(base_url)
  defp endpoint(_provider, :unknown), do: nil

  defp endpoint(provider, nil) do
    with atom when is_atom(atom) and not is_nil(atom) <-
           Enum.find(ReqLLM.Providers.list(), &(Atom.to_string(&1) == provider)),
         url when is_binary(url) <- configured_base_url(atom) || default_base_url(atom) do
      origin(url)
    else
      _unknown -> nil
    end
  end

  defp configured_base_url(provider) do
    case Application.get_env(:req_llm, provider) do
      config when is_list(config) -> Keyword.get(config, :base_url)
      %{base_url: url} -> url
      _unconfigured -> nil
    end
  end

  defp default_base_url(provider) do
    with {:ok, module} <- ReqLLM.provider(provider),
         true <- Code.ensure_loaded?(module) and function_exported?(module, :default_base_url, 0) do
      module.default_base_url()
    else
      _none -> nil
    end
  end

  defp origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        URI.to_string(%URI{scheme: scheme, host: host, port: port})

      _unparsed ->
        nil
    end
  end

  defp locked(holder) do
    who =
      [
        holder |> Map.get(:os_pid) |> then(&if(&1, do: "pid #{&1}")),
        holder |> Map.get(:host) |> then(&if(&1, do: "on #{&1}")),
        holder |> Map.get(:since) |> since()
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")

    who = if who == "", do: "", else: " (#{who})"

    "this session is open in another lmx#{who}. Close it there, or, if that " <>
      "process is gone, delete #{Map.get(holder, :path) || "its lock file"} and try again"
  end

  defp since(%DateTime{} = at), do: "since " <> Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")

  defp since(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> since(datetime)
      _unparsed -> "since " <> at
    end
  end

  defp since(at) when is_integer(at), do: at |> DateTime.from_unix!() |> since()
  defp since(_unknown), do: nil

  @doc "The environment variable a provider's key is read from, as a person would set it."
  @spec key_variable(provider :: String.t() | atom()) :: String.t()
  def key_variable(provider) do
    name = to_string(provider)

    case Enum.find(ReqLLM.Providers.list(), &(Atom.to_string(&1) == name)) do
      nil -> "#{String.upcase(name)}_API_KEY"
      atom -> ReqLLM.Keys.env_var_name(atom)
    end
  end

  @doc "The provider of a model spec, for the sentences above."
  @spec provider(model :: String.t()) :: String.t() | nil
  def provider(model), do: ModelSpec.provider(model)
end
