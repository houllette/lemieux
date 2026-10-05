defmodule Lemieux.CLI.Ollama do
  @moduledoc """
  Discovers models available from the local Ollama daemon and Ollama Cloud.

  This is host-side discovery, not another provider adapter. Model requests
  still go through `Lemieux.Providers.ReqLLM`; the CLI only asks Ollama's tag
  endpoints which model names it should offer in completion. Local models use
  the `ollama` provider; direct Cloud models use `ollama_cloud` so one session
  can distinguish the unauthenticated local daemon from the authenticated
  remote service.

  Cloud discovery is enabled by `OLLAMA_API_KEY` and authenticates with the
  bearer header Ollama documents. Both lookups are best effort and deliberately
  quick. An absent, starting, or malformed endpoint produces no choices from
  that endpoint, so opening the TUI never depends on either service.

  A tag that cannot chat — an embedding model, by its capabilities or, from
  a daemon too old to list them, by its name or family — is not offered at
  all: the alphabet puts `all-minilm` and `bge-m3` first, and a menu that
  offered them offered models that cannot answer. Nor does `/provider
  ollama` take whichever tag sorts first, as it did: on a running screen it
  switches to `local_model/2`'s pick, which
  `Lemieux.CLI.TUI.discovered_models/2` puts first, and after a failed start
  it starts on that pick (`Lemieux.CLI.TUI.restart_options/3`).

  One discovery asks `/api/tags` once. `served/2` is that request, and
  `models/2` and `local_model/2` take its answer as `:served` rather than
  asking again: the terminal UI's discovery used to ask three times for one
  list, from a background task, on every start.

  ## Names

  Ollama completes a model name before it compares it: no tag means
  `:latest`, the default registry and namespace
  (`registry.ollama.ai/library/`) may be written out or left off, and case
  does not matter. `/api/tags` always lists the completed form, and people
  write the short one (`--model ollama:llama3.2`), so names are compared
  completed here too. Compared as written, a model the daemon was serving
  looked absent, and `Lemieux.CLI.Models` moved the person off their own
  choice.

  ## Which local model `lmx` starts on by itself

  `local_model/2` answers for `Lemieux.CLI.Models` when nothing chose a
  model and no provider has a key. It used to take the alphabetically first
  tag, and the alphabet favours embedding models — `all-minilm`, `bge-m3`
  and `mxbai-embed-large` sort before `llama` and `qwen` — which cannot
  answer a chat request at all, let alone call a tool, so a newcomer's first
  prompt failed. Now:

    * only a tag whose capabilities (from `/api/show`, or `/api/tags` where
      the daemon lists them there) include `tools` is chosen: an agent that
      cannot call tools cannot read a file. A daemon too old to report
      capabilities still never gets a tag that looks like an embedding model;
    * among those, the one `lmx` used most recently (`:recent`), then the
      most recently pulled or modified tag, then the alphabet;
    * the context length the model was trained for is read from
      `/api/show` — the architecture's own key, since a vision model also
      describes its image encoder's — so later code can compare it with the
      window Ollama actually serves. It is not that window: unless
      `OLLAMA_CONTEXT_LENGTH` says otherwise, Ollama sizes the window by GPU
      memory — 4096 tokens under about 23 GiB, 32768 under about 47 GiB
      (`Lemieux.Providers.OllamaWindow`) — and a longer request loses its
      beginning, the person's task included, without an error. That is why
      every place offering a local model says to set it to 32768 or more
      (65536 recommended).

  This probe waits longer for an answer than the completion list's (1.5 s
  against half a second): it decides what a session runs on, and under load
  a running daemon missing the short deadline sent people to a paid
  provider's key panel instead. Connecting is still bounded at 250 ms, so a
  daemon that is not running costs nothing. `/api/show` is asked about the
  candidates in order, at most eight of them, and once it fails to answer,
  the rest are judged on what `/api/tags` said.
  """

  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Options
  alias Lemieux.ModelSpec

  @default_base_url "http://localhost:11434/v1"
  @cloud_base_url "https://ollama.com/v1"
  @connect_timeout 250
  @receive_timeout 500
  @probe_timeout 1_500
  @show_limit 8

  @type get ::
          (url :: String.t(), opts :: keyword() ->
             {:ok, Req.Response.t()} | {:error, term()})

  @typedoc """
  A tag the local daemon serves, with what discovery read about it:
  `capabilities` as Ollama names them (`nil` when the daemon did not say, an
  empty list included),
  the `context_length` the model was trained for (`nil` when unknown; not
  the window Ollama serves), when the tag was last `modified_at`, and its
  model `families`.
  """
  @type served :: %{
          model: String.t(),
          capabilities: [String.t()] | nil,
          context_length: pos_integer() | nil,
          modified_at: String.t() | nil,
          families: [String.t()]
        }

  @doc """
  Returns the fully qualified model tags currently available from Ollama
  that can chat (see the module documentation).

  When the selected model is already an `ollama:` model, an explicit
  `--base-url` is the local discovery target. The same applies to an
  `ollama_cloud:` model and Cloud discovery. A base URL belonging to another
  provider is never mistaken for Ollama.

  `opts` takes `:served`, what `served/2` already answered, in place of
  asking the local daemon again; `:get` in place of `Req.get/2`; and
  `:api_key` for Ollama Cloud.
  """
  @spec models(options :: Options.t(), opts :: keyword()) :: [String.t()]
  def models(options, opts \\ [])
  def models(%Options{ixway: endpoint}, _opts) when is_binary(endpoint), do: []

  def models(%Options{} = options, opts) when is_list(opts) do
    get = Keyword.get(opts, :get, &Req.get/2)

    local =
      case Keyword.fetch(opts, :served) do
        {:ok, served} -> chat_models(served)
        :error -> fetch_models(get, local_url(options, "/api/tags"), request_options(), "ollama")
      end

    cloud =
      case cloud_api_key(opts, options) do
        nil ->
          []

        key ->
          fetch_models(
            get,
            cloud_url(options, "/api/tags"),
            cloud_request_options(key),
            "ollama_cloud"
          )
      end

    Enum.sort(Enum.uniq(local ++ cloud))
  end

  @doc """
  The local model to start on when nothing chose one, per "Which local model
  `lmx` starts on by itself" above.

  `{:error, :unreachable}` when the daemon did not answer, and
  `{:error, :none}` when it answered without a tag that can call tools —
  which a person fixes differently, so the first-run panel says which.
  `opts` takes `:recent` (model specs, most recent first), `:served` (what
  `served/2` already answered, so `/api/tags` is not asked again) and, for
  tests, `:get` and `:post` in place of `Req.get/2` and `Req.post/2`.
  """
  @spec local_model(options :: Options.t(), opts :: keyword()) ::
          {:ok, served()} | {:error, :unreachable | :none}
  def local_model(options, opts \\ [])

  def local_model(%Options{ixway: endpoint}, _opts) when is_binary(endpoint),
    do: {:error, :unreachable}

  def local_model(%Options{} = options, opts) when is_list(opts) do
    case Keyword.get_lazy(opts, :served, fn -> served(options, opts) end) do
      {:ok, tags} ->
        tags
        |> preferred(Keyword.get(opts, :recent, []))
        |> Enum.reject(&without_tools?/1)
        |> Enum.take(@show_limit)
        |> first_usable(Keyword.get(opts, :post, &Req.post/2), local_url(options, "/api/show"))

      :unreachable ->
        {:error, :unreachable}
    end
  end

  @doc """
  The tag the local daemon serves under `model`'s name, described as
  `local_model/2` describes its pick — what `Lemieux.CLI.Models` checks a
  remembered local model against before starting on it.

  Names are compared as Ollama compares them (see "Names" above), so
  `ollama:llama3.2` finds `llama3.2:latest`. `{:error, :unreachable}` when
  the daemon did not answer, and `{:error, :none}` when it serves no tag by
  that name that can chat. One `/api/show` request describes the tag found;
  a daemon that does not answer it leaves what `/api/tags` said. `opts` is as
  for `local_model/2`, without `:recent`.
  """
  @spec serving(options :: Options.t(), model :: String.t(), opts :: keyword()) ::
          {:ok, served()} | {:error, :unreachable | :none}
  def serving(options, model, opts \\ [])

  def serving(%Options{ixway: endpoint}, _model, _opts) when is_binary(endpoint),
    do: {:error, :unreachable}

  def serving(%Options{} = options, model, opts) when is_binary(model) and is_list(opts) do
    wanted = canonical(model)

    with {:ok, tags} <- served(options, opts),
         %{} = tag <- Enum.find(tags, &(canonical(&1.model) == wanted)) do
      {described, _mode} =
        described(
          tag,
          Keyword.get(opts, :post, &Req.post/2),
          local_url(options, "/api/show"),
          :show
        )

      described = described || tag
      if can_chat?(described), do: {:ok, described}, else: {:error, :none}
    else
      :unreachable -> {:error, :unreachable}
      nil -> {:error, :none}
    end
  end

  @doc """
  Every tag the local daemon serves, as `/api/tags` describes it, or
  `:unreachable`. No `/api/show` requests.
  """
  @spec served(options :: Options.t(), opts :: keyword()) :: {:ok, [served()]} | :unreachable
  def served(%Options{} = options, opts \\ []) do
    get = Keyword.get(opts, :get, &Req.get/2)

    case get.(local_url(options, "/api/tags"), probe_options()) do
      {:ok, %Req.Response{status: 200, body: %{"models" => models}}} when is_list(models) ->
        {:ok,
         models |> Enum.map(&served_tag/1) |> Enum.reject(&is_nil/1) |> Enum.uniq_by(& &1.model)}

      _unavailable ->
        :unreachable
    end
  rescue
    _boundary_error -> :unreachable
  catch
    _kind, _reason -> :unreachable
  end

  defp served_tag(%{} = tag) do
    case tag["name"] || tag["model"] do
      name when is_binary(name) and name != "" ->
        details = if is_map(tag["details"]), do: tag["details"], else: %{}

        %{
          model: qualify(name, "ollama"),
          capabilities: strings(tag["capabilities"]),
          context_length: positive(details["context_length"]),
          modified_at: if(is_binary(tag["modified_at"]), do: tag["modified_at"]),
          families: families(details)
        }

      _nameless ->
        nil
    end
  end

  defp served_tag(_other), do: nil

  defp families(details) do
    [details["family"] | List.wrap(details["families"])]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  # Most recently used first, then most recently modified, then by name, so
  # the same machine gives the same answer on every start. The recent list
  # holds names as people wrote them, so both sides are compared completed.
  defp preferred(tags, recent) do
    rank =
      recent
      |> Enum.map(&canonical/1)
      |> Enum.with_index()
      |> Enum.reverse()
      |> Map.new()

    Enum.sort_by(
      tags,
      &{Map.get(rank, canonical(&1.model), length(recent)), -modified(&1), &1.model}
    )
  end

  # A model specification with its Ollama name completed and lower-cased, for
  # comparison only (see "Names" in the module documentation); another
  # provider's specification is left as it is.
  defp canonical("ollama:" <> name), do: "ollama:" <> complete(String.downcase(name))
  defp canonical(model), do: model

  defp complete(name) do
    name =
      name
      |> String.replace_prefix("registry.ollama.ai/", "")
      |> String.replace_prefix("library/", "")

    if name |> String.split("/") |> List.last() |> String.contains?(":"),
      do: name,
      else: name <> ":latest"
  end

  defp modified(%{modified_at: at}) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> DateTime.to_unix(datetime, :microsecond)
      {:error, _reason} -> 0
    end
  end

  defp modified(_tag), do: 0

  # What `/api/tags` already said lacks tools needs no `/api/show` to rule out.
  defp without_tools?(%{capabilities: capabilities}) when is_list(capabilities),
    do: "tools" not in capabilities

  defp without_tools?(_unknown), do: false

  # `/api/show` is asked until it fails to answer once; after that, what
  # `/api/tags` said is all there is, rather than a timeout per candidate.
  defp first_usable(candidates, post, url) do
    candidates
    |> Enum.reduce_while(:show, fn tag, mode ->
      {described, mode} = described(tag, post, url, mode)
      if usable?(described), do: {:halt, {:ok, described}}, else: {:cont, mode}
    end)
    |> case do
      {:ok, served} -> {:ok, served}
      _mode -> {:error, :none}
    end
  end

  defp described(tag, _post, _url, :tags_only), do: {tag, :tags_only}

  defp described(tag, post, url, :show) do
    case show(post, url, ModelSpec.model_id(tag.model)) do
      {:ok, shown} ->
        {%{
           tag
           | capabilities: strings(shown["capabilities"]) || tag.capabilities,
             context_length: context_length(shown) || tag.context_length
         }, :show}

      :refused ->
        {nil, :show}

      :silent ->
        {tag, :tags_only}
    end
  end

  # An HTTP error is an answer about one tag (`:refused`), which the daemon
  # will not describe and so is not offered; no answer at all (`:silent`) is
  # the daemon, and asking about the next tag would only wait as long again.
  defp show(post, url, name) do
    case post.(url, Keyword.put(probe_options(), :json, %{"model" => name})) do
      {:ok, %Req.Response{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %Req.Response{}} -> :refused
      _unanswered -> :silent
    end
  rescue
    _boundary_error -> :silent
  catch
    _kind, _reason -> :silent
  end

  # `model_info` keys the trained length by architecture
  # (`"gemma4.context_length"`, under `"general.architecture" => "gemma4"`).
  # A vision model describes its image encoder in the same map, possibly
  # with a length of its own, so the architecture's key comes first; the
  # suffix, in key order so the answer does not depend on how a large map
  # happens to iterate, is for a daemon that does not name the architecture.
  defp context_length(%{"model_info" => %{} = info}) do
    positive(info["#{info["general.architecture"]}.context_length"]) ||
      info |> Enum.sort() |> Enum.find_value(&suffixed_length/1)
  end

  defp context_length(_shown), do: nil

  defp suffixed_length({key, value}) when is_binary(key),
    do: if(String.ends_with?(key, ".context_length"), do: positive(value))

  defp suffixed_length(_entry), do: nil

  defp usable?(nil), do: false

  defp usable?(%{capabilities: capabilities}) when is_list(capabilities),
    do: "tools" in capabilities

  defp usable?(served), do: can_chat?(served)

  # Whether a tag can answer a chat request at all. Ollama gives every model
  # either `completion` or `embedding`; a daemon that reports no
  # capabilities is judged by name and family, and only the embedding kind is
  # ruled out, since that is the one that cannot chat whatever else is true
  # of it.
  defp can_chat?(%{capabilities: capabilities}) when is_list(capabilities),
    do: "completion" in capabilities

  defp can_chat?(%{model: model, families: families}) do
    not String.contains?(String.downcase(model), "embed") and
      not Enum.any?(families, &(&1 in ["bert", "nomic-bert"]))
  end

  # An empty list says no more than an absent one, and reading it as "no
  # capabilities" would rule a model out on a daemon's silence.
  defp strings([_ | _] = values), do: values |> Enum.filter(&is_binary/1) |> nil_if_empty()
  defp strings(_absent), do: nil

  defp nil_if_empty([]), do: nil
  defp nil_if_empty(values), do: values

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_other), do: nil

  defp probe_options do
    [
      retry: false,
      receive_timeout: @probe_timeout,
      connect_options: [timeout: @connect_timeout]
    ]
  end

  defp fetch_models(get, url, request_options, provider) do
    case get.(url, request_options) do
      {:ok, %Req.Response{status: 200, body: %{"models" => models}}} when is_list(models) ->
        models
        |> Enum.filter(&chats?/1)
        |> Enum.map(&tag(&1, provider))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      _unavailable ->
        []
    end
  rescue
    _boundary_error -> []
  catch
    _kind, _reason -> []
  end

  defp cloud_api_key(opts, options) do
    case Keyword.fetch(opts, :api_key) do
      {:ok, key} when is_binary(key) and key != "" ->
        key

      {:ok, _disabled_or_invalid} ->
        nil

      :error ->
        resolved_ollama_key(options)
    end
  end

  defp resolved_ollama_key(options) do
    case ReqLLM.Keys.get(:ollama) do
      {:ok, key, _source} ->
        key

      {:error, _missing} ->
        ambient =
          System.get_env("OLLAMA_API_KEY") || Application.get_env(:req_llm, :ollama_api_key)

        if is_nil(ambient), do: Config.api_keys(options.config)["ollama_cloud"]
    end
  end

  defp request_options do
    [
      retry: false,
      receive_timeout: @receive_timeout,
      connect_options: [timeout: @connect_timeout]
    ]
  end

  defp cloud_request_options(key) do
    Keyword.put(request_options(), :headers, [{"authorization", "Bearer #{key}"}])
  end

  defp local_url(options, endpoint) do
    base_url =
      if ModelSpec.provider(options.model) == "ollama" and is_binary(options.base_url),
        do: options.base_url,
        else: configured_base_url()

    api_url(base_url, endpoint)
  end

  defp cloud_url(options, endpoint) do
    base_url =
      if ModelSpec.provider(options.model) == "ollama_cloud" and is_binary(options.base_url),
        do: options.base_url,
        else: @cloud_base_url

    api_url(base_url, endpoint)
  end

  defp api_url(base_url, endpoint) do
    uri = URI.parse(base_url)

    path =
      uri.path |> to_string() |> String.trim_trailing("/") |> String.replace_suffix("/v1", "")

    %{uri | path: path <> endpoint, query: nil, fragment: nil}
    |> URI.to_string()
  end

  defp configured_base_url do
    case Application.get_env(:req_llm, :ollama, []) do
      config when is_list(config) -> Keyword.get(config, :base_url, @default_base_url)
      %{base_url: base_url} when is_binary(base_url) -> base_url
      %{"base_url" => base_url} when is_binary(base_url) -> base_url
      _unconfigured -> @default_base_url
    end
  end

  # `models/2`'s local list from tags `served/2` has already read: the same
  # names `fetch_models/4` would make of the same answer.
  defp chat_models({:ok, tags}),
    do: tags |> Enum.filter(&can_chat?/1) |> Enum.map(& &1.model) |> Enum.uniq() |> Enum.sort()

  defp chat_models(:unreachable), do: []

  # A listing entry, judged before it is reduced to a name.
  defp chats?(entry) do
    case served_tag(entry) do
      nil -> false
      served -> can_chat?(served)
    end
  end

  defp tag(%{"name" => name}, provider) when is_binary(name) and name != "",
    do: qualify(name, provider)

  defp tag(%{"model" => name}, provider) when is_binary(name) and name != "",
    do: qualify(name, provider)

  defp tag(_unknown, _provider), do: nil

  defp qualify(name, provider) do
    prefix = provider <> ":"
    if String.starts_with?(name, prefix), do: name, else: prefix <> name
  end
end
