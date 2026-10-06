defmodule Lemieux.CLI.Config do
  @moduledoc """
  Optional personal host settings from `~/.lmx/config.json`.

  This is JSON data, never executable Elixir or workspace-discovered policy.
  An absent default file is created with ordinary defaults; a malformed file or missing
  explicitly selected file is an error. Silently ignoring a broken router
  setting could send a request directly to a vendor.

  Routing precedence is an explicit flag choice, then environment, then the
  file. `--router direct` disables a saved Ixway route without deleting it.
  The file's model and system prompt are defaults for new conversations;
  only actual flags enter `Options.given` and override a resumed transcript.

  Credentials stay in private host state. Files containing keys must have
  owner-only permissions, and no config file may be writable by group/others.
  Errors describe the field rather than quoting JSON or parser snippets.

  Search credentials live in `"web_search_providers"`, separately from model
  `"providers"`: a search key must never become an inference credential or a
  TUI model-provider choice. The CLI uses a configured Brave key to equip its
  research tools by default; `"web_search": "none"` disables that route without
  deleting the key. No request is sent until the agent calls a web tool.

  Three keys are data that stand in for code, and are held to that line.
  `"extensions"` is a list of names, each a directory under the personal
  extensions root that `Lemieux.CLI.Extensions` loads; a path or a module
  name is refused, because the manifest that names code has to live inside
  a directory the person populated. `"disabled_extensions"` is a separate
  list of shipped recipe names to withhold. It never names a module or
  disables a host's own policy. `"themes"` is a map of palettes in
  `Lemieux.TUI.Theme`'s map form, validated here so every bad `group.slot`
  is named at startup rather than shrugged at when the screen draws; the
  `"theme"` that starts a sitting may then name one of them. `"keys"` is a
  map from key description to action name in `Lemieux.TUI.Keys`'s grammar,
  validated the same way, so every key that does not parse and every action
  that does not exist is named in the one sentence.

  ## Unknown fields are named, and most are only warnings

  A field this build does not know is named — with the closest known field
  when there is a plausible one — and ignored, rather than stopping every
  command: a file written for a newer `lmx`, or a typo in `"thme"`, is not a
  reason `lmx log` should refuse to run. Two kinds still fail, because
  ignoring them could change where requests go or what credentials a request
  carries: a field whose closest match is a routing or credential field
  (`"modle"`, `"ixwya"`, `"provider"`), and the retired `"api_keys"` and
  `"preferred_models"` maps, whose contents moved into `"providers"`. Inside
  a structured section (`"providers"`, `"ixway"`, `"permissions"`…) every
  unknown key fails, naming the section and the key, since those sections
  are small and a misspelt key there silently disables what it configured.
  `warnings/1` returns what was ignored; the hosts show it at startup.

  A value that is wrong names the field it is in, down to the key —
  `ixway.api_key`, `web_search_providers.brave.api_key` — and what the field
  takes, because a sentence that names only the section
  (`Invalid lmx config field: web_search_providers.`) sends the person
  through every key in it, one start at a time (issue #3).

  ## An empty key is a placeholder, not a credential

  An `api_key` that is empty or blank — `"api_key": ""`, left in the file
  while setting things up — is read as no key at all: named at startup like
  an unknown field, and dropped, so every later check sees the file without
  it. The runtime already treats an empty key as absent wherever it looks for
  one (`Lemieux.CLI.Models`, `Lemieux.CLI.Runtime`, the Jev route), so
  refusing the file for it protected nothing; it only kept the screen that
  saves a real key from opening. A key that spans lines, or is not text, is
  still an error, since that is never a placeholder. `put_provider_key/3`
  still refuses to save an empty key: writing a placeholder is not saving a
  credential.

  ## Writing

  `put_provider_key/3` and `put_model/2` are how the first-run screen saves
  what a person chose. They rewrite the whole file through a private
  temporary file and a rename, so a crash leaves the old file or the new one
  and never half of either, and the result is always mode 0600 because it may
  now hold a key. They refuse to write a file this module would then refuse
  to read.

  What the file never holds is a module. The status line, the follow-up
  hint, a tool's receipt, a slash command and the layout that places the
  screen's regions are code, and therefore an embedding host's option or an
  extension's to set on the harness — never a key here. A config file that
  named a module would be a config file that loads code, and
  `Lemieux.Extension.Profile` records why this file never resolves a module
  name to code.
  """

  alias Lemieux.CLI.Extensions
  alias Lemieux.CLI.Options
  alias Lemieux.Extensions.A2A, as: A2AExtension
  alias Lemieux.Ixway
  alias Lemieux.ModelSpec
  alias Lemieux.TUI.Keys
  alias Lemieux.TUI.Processing
  alias Lemieux.TUI.Theme

  @derive {Inspect, only: []}
  defstruct settings: %{}, limits: [], path: nil, warnings: [], personal: false

  @type t :: %__MODULE__{
          settings: map(),
          limits: keyword(),
          path: Path.t() | nil,
          warnings: [String.t()],
          personal: boolean()
        }

  @fields ~w(version model providers base_url ixway system sessions_dir context_window web_search
             web_search_providers web_fetch mouse project_mcp delegate a2a_peers theme themes keys processing extensions disabled_extensions
             auto_compaction compaction_price_tiers keep_recent_tokens summary_model jev_compaction
             max_turns max_requests max_cost_usd scrub_credentials credential_allowlist hooks
             permissions sandbox mcp_servers mcp_discovery plugin_dirs marketplaces plugins
             extension_options scout_model verify input_modalities notifications skills)
  # A misspelling of one of these is refused rather than ignored: ignoring it
  # could send a request somewhere other than where the file meant, or
  # without the credential it meant to supply.
  @routing_fields ~w(model providers base_url ixway)
  @retired_fields %{
    "api_keys" => "keys now live in providers.NAME.api_key",
    "preferred_models" => "per-provider models now live in providers.NAME.model"
  }
  @permission_fields ~w(mode allow deny ask non_interactive)
  @permission_modes ~w(off ask default accept_edits acceptEdits auto full_auto bypassPermissions
                       read_only plan)
  @sandbox_fields ~w(enabled backend network localhost writable hidden)
  @verify_fields ~w(enabled command max_continuations timeout_ms)
  @skills_fields ~w(omarchy disabled)
  # What a model can be shown besides text, as the model catalog names it.
  # A fixed map rather than `String.to_existing_atom/1`: the file is data.
  @modalities %{"text" => :text, "image" => :image, "pdf" => :pdf}
  @price_fields ~w(up_to input_per_million output_per_million cached_input_per_million)
  @ixway_fields ~w(enabled endpoint api_key model effort headers)
  @provider_fields ~w(api_key model effort)
  @jev_fields ~w(mode route model endpoint api_key max_evaluations max_cost_usd
                 reservation_per_call_usd input_per_million output_per_million)
  @shipped_extensions ~w(mcp interactive web elixir workspace delegation a2a jev_compaction
                         environment_context planning verify search apply_patch checkpoints
                         mcp_discovery)

  @doc "Returns the optional personal configuration path."
  @spec default_path() :: Path.t()
  def default_path, do: Path.expand("~/.lmx/config.json")

  @doc "Loads an explicitly selected file, or creates and loads the personal default."
  @spec from_cli(parsed :: keyword(), default_model :: String.t()) ::
          {:ok, t()} | {:error, String.t()}
  def from_cli(parsed, default_model) do
    case parsed[:config] || Options.env("LMX_CONFIG") do
      "none" -> {:ok, %__MODULE__{}}
      nil -> load_default(default_path(), default_model)
      path -> load(Path.expand(path))
    end
  end

  @doc """
  Whether these are a person's settings — read from a file, or the built-in
  defaults standing in for a default file that could not be created —
  rather than none at all, which is what `--config none` asks for.

  Both of the last two have no file and no `path/1`, and they differ in what
  `lmx` may guess: a hermetic run guesses nothing from the machine, while a
  person whose home directory is read-only still has keys in the
  environment and maybe a local Ollama, and `Lemieux.CLI.Models` uses them.
  A `nil` configuration is no settings, as everywhere in this module.
  """
  @spec personal?(config :: t() | nil) :: boolean()
  def personal?(%__MODULE__{personal: personal}), do: personal
  def personal?(nil), do: false

  @doc """
  Loads personal settings, creating a private basic file only when absent.

  A default file that cannot be created — a read-only home directory, a CI
  container — is not a reason to refuse every command. The defaults apply,
  with a warning saying the file could not be written; an explicit
  `--config PATH` that does not exist still fails, because somebody named it.
  """
  @spec load_default(path :: Path.t(), default_model :: String.t()) ::
          {:ok, t()} | {:error, String.t()}
  def load_default(path, _default_model) do
    case File.lstat(path) do
      {:error, :enoent} -> create_default(path)
      _existing_or_unreadable -> load(path)
    end
  end

  @doc "The file these settings were read from, or `nil` for `--config none`."
  @spec path(config :: t() | nil) :: Path.t() | nil
  def path(nil), do: nil
  def path(%__MODULE__{path: path}), do: path

  @doc """
  Sentences for the host to show at startup (`Lemieux.CLI.Runtime` makes
  them notices): fields that were ignored, a default file that could not be
  created, and what `warn/2` added.
  """
  @spec warnings(config :: t() | nil) :: [String.t()]
  def warnings(nil), do: []
  def warnings(%__MODULE__{warnings: warnings}), do: warnings

  @doc """
  Adds `warning` to `warnings/1`: something the host decided about these
  settings that the person should hear at startup — `Lemieux.CLI.Models`
  moving them off a remembered model, say. A `nil` configuration has no
  settings to speak for and stays `nil`.
  """
  @spec warn(config :: t() | nil, warning :: String.t()) :: t() | nil
  def warn(nil, _warning), do: nil

  def warn(%__MODULE__{warnings: warnings} = config, warning) when is_binary(warning),
    do: %{config | warnings: warnings ++ [warning]}

  defp create_default(path) do
    directory = Path.dirname(path)
    temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    contents = """
    {
      "version": 1,
      "providers": {},
      "ixway": {
        "enabled": false
      }
    }
    """

    # Link a completed private file into place without replacing an existing
    # name. Concurrent starts must neither read partial JSON nor overwrite a
    # config another process (or the user) just created.
    try do
      with :ok <- create_directory(directory),
           :ok <- File.write(temporary, contents, [:exclusive]),
           :ok <- File.chmod(temporary, 0o600),
           :ok <- File.ln(temporary, path) do
        load(path)
      else
        {:error, :eexist} ->
          load(path)

        {:error, reason} ->
          {:ok,
           %__MODULE__{
             personal: true,
             warnings: [
               "Could not create #{path} (#{:file.format_error(reason)}); " <>
                 "using built-in defaults for this run."
             ]
           }}
      end
    after
      File.rm(temporary)
    end
  end

  defp create_directory(directory) do
    case File.mkdir(directory) do
      :ok -> File.chmod(directory, 0o700)
      {:error, :eexist} -> :ok
      error -> error
    end
  end

  @doc "Reads validated JSON without exposing credentials in errors."
  @spec load(path :: Path.t(), options :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def load(path, options \\ []) do
    with {:ok, stat} <- File.stat(path),
         :ok <- regular_file(stat),
         {:ok, content} <- File.read(path),
         {:ok, settings} <- decode(content),
         {:ok, settings, warnings} <- without_unknown(settings),
         {settings, warnings} = without_empty_keys(settings, warnings),
         :ok <- validate(settings),
         :ok <- permissions(stat, settings) do
      {:ok, %__MODULE__{settings: settings, path: path, warnings: warnings, personal: true}}
    else
      {:error, :enoent} ->
        missing_file(options)

      {:error, reason} when is_atom(reason) ->
        {:error, "Cannot read lmx configuration file (#{reason})."}

      {:error, message} ->
        {:error, message}
    end
  end

  @doc """
  Saves `key` as `provider`'s credential in the config file at `path`.

  Written as `providers.PROVIDER.api_key`, where `Lemieux.CLI.Runtime` already
  looks for saved keys, and only after the whole resulting file has been
  checked: a key saved into a file `lmx` would then refuse to read would lock
  the person out on the next start. The file is private (0600) afterwards
  whatever it was before, because it now holds a secret. A missing file is
  created, with its directory, as `load_default/2` would.
  """
  @spec put_provider_key(path :: Path.t(), provider :: String.t(), key :: String.t()) ::
          :ok | {:error, String.t()}
  def put_provider_key(path, provider, key) when is_binary(path) do
    cond do
      not valid_provider_name?(provider) ->
        {:error, "#{inspect(provider)} is not a provider name lmx can save a key for."}

      not valid_key?(key) ->
        {:error, "That key is empty or spans several lines; nothing was saved."}

      true ->
        update(path, fn settings ->
          providers = Map.get(settings, "providers", %{})
          section = providers |> Map.get(provider, %{}) |> Map.put("api_key", String.trim(key))
          Map.put(settings, "providers", Map.put(providers, provider, section))
        end)
    end
  end

  @doc """
  Saves `model` as the model new sessions start with, in the file at `path`.

  The top-level `"model"`, which a flag and `LMX_MODEL` still override.
  """
  @spec put_model(path :: Path.t(), model :: String.t()) :: :ok | {:error, String.t()}
  def put_model(path, model) when is_binary(path) do
    if valid_model?(model),
      do: update(path, &Map.put(&1, "model", model)),
      else: {:error, "#{inspect(model)} is not a model specification (provider:model)."}
  end

  @doc """
  Saves one MCP server under `"mcp_servers"`, the person's own servers.

  Written in the shape `.mcp.json` and Claude Code use — the transport as
  `"type"` — without the `"name"`, which is the key, or the `"source"`,
  which says where a server was read from rather than what it is.
  """
  @spec put_mcp_server(path :: Path.t(), server :: map()) :: :ok | {:error, String.t()}
  def put_mcp_server(path, %{"name" => name} = server) when is_binary(path) and is_binary(name) do
    written =
      case server |> Map.drop(["name", "source"]) |> Map.pop("transport") do
        {transport, rest} when transport in ["stdio", "http"] -> Map.put(rest, "type", transport)
        {nil, rest} -> rest
        {_custom, _rest} -> Map.drop(server, ["name", "source"])
      end

    update(path, fn settings ->
      Map.update(settings, "mcp_servers", %{name => written}, &Map.put(&1, name, written))
    end)
  end

  def put_mcp_server(_path, _server), do: {:error, "An MCP server needs a name."}

  @doc """
  Rewrites the config file at `path` through `fun`, which receives and returns
  the decoded settings.

  The result is validated as `load/2` would read it, then written to a
  private temporary file beside the original and renamed over it. Fields the
  file already had and this build does not know are kept: rewriting the file
  must not delete what a newer `lmx` wrote into it.
  """
  @spec update(path :: Path.t(), fun :: (map() -> map())) :: :ok | {:error, String.t()}
  def update(path, fun) when is_binary(path) and is_function(fun, 1) do
    path = Path.expand(path)

    with {:ok, settings} <- current(path),
         updated = fun.(settings),
         {:ok, known, _warnings} <- without_unknown(updated),
         :ok <- validate(known) do
      write_private(path, JSON.encode!(updated))
    end
  end

  defp current(path) do
    case File.read(path) do
      {:ok, content} -> decode(content)
      {:error, :enoent} -> {:ok, %{"version" => 1}}
      {:error, reason} -> {:error, "Cannot read lmx configuration file (#{reason})."}
    end
  end

  defp write_private(path, contents) do
    directory = Path.dirname(path)
    temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

    try do
      with :ok <- mkdir_private(directory),
           :ok <- write_new_private(temporary, contents <> "\n"),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        {:error, reason} ->
          {:error, "Cannot write #{path} (#{:file.format_error(reason)})."}
      end
    after
      File.rm(temporary)
    end
  end

  # Created empty, made 0600, and only then given the contents, through the
  # descriptor that created it. Written first and made private after, the
  # file held the keys at the umask's mode (0644 under the usual 022) for a
  # moment, readable by anyone who can list a `--config` directory (found in
  # review, 2026-10). Erlang cannot create a file with a mode, so empty is
  # what that moment holds instead.
  defp write_new_private(path, contents) do
    with {:ok, device} <- File.open(path, [:write, :exclusive, :binary]) do
      written = with :ok <- File.chmod(path, 0o600), do: IO.binwrite(device, contents)
      closed = File.close(device)
      if written == :ok, do: closed, else: written
    end
  end

  defp mkdir_private(directory) do
    case File.stat(directory) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _other} -> {:error, :enotdir}
      {:error, :enoent} -> with :ok <- File.mkdir_p(directory), do: File.chmod(directory, 0o700)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The configured `"input_modalities"` as the atoms a session takes, or `nil`.

  For a model the catalog does not know — a local vision model — so tools
  may attach images and PDFs to what it is shown.
  """
  @spec input_modalities(config :: t() | nil) :: [atom()] | nil
  def input_modalities(config) do
    case get(config, "input_modalities") do
      nil -> nil
      names -> Enum.map(names, &Map.fetch!(@modalities, &1))
    end
  end

  @doc "Reads one setting; nil config is the empty host configuration."
  @spec get(config :: t() | nil, key :: String.t(), default :: term()) :: term()
  def get(config, key, default \\ nil)
  def get(nil, _key, default), do: default
  def get(%__MODULE__{settings: settings}, key, default), do: Map.get(settings, key, default)

  @doc "Returns keys saved in direct-provider sections."
  @spec api_keys(config :: t() | nil) :: %{optional(String.t()) => String.t()}
  def api_keys(config) do
    for {provider, %{"api_key" => key}} <- get(config, "providers", %{}),
        into: %{},
        do: {provider, key}
  end

  @doc "Returns the private saved key for one search provider, without enabling search."
  @spec web_search_api_key(config :: t() | nil, provider :: String.t()) :: String.t() | nil
  def web_search_api_key(config, provider) do
    config
    |> get("web_search_providers", %{})
    |> Map.get(provider, %{})
    |> Map.get("api_key")
  end

  @doc "Returns configured per-provider model choices for TUI switching."
  @spec preferred_models(config :: t() | nil) :: %{optional(String.t()) => String.t()}
  def preferred_models(config) do
    preferred =
      for {provider, %{"model" => model}} <- get(config, "providers", %{}),
          into: %{},
          do: {provider, model}

    case get(config, "ixway", %{})["model"] do
      nil -> preferred
      model -> Map.put(preferred, "ixway", model)
    end
  end

  @doc "Returns the file's direct startup model, if one is explicit or unambiguous."
  @spec direct_model(config :: t() | nil) :: String.t() | nil
  def direct_model(config) do
    get(config, "model") ||
      case config
           |> get("providers", %{})
           |> Enum.flat_map(fn
             {_provider, %{"model" => model}} -> [model]
             _other -> []
           end) do
        [model] -> model
        _otherwise -> nil
      end
  end

  @doc "Returns the saved effort for a selected model's route, if configured."
  @spec effort(config :: t() | nil, model :: String.t()) :: String.t() | nil
  def effort(config, model) do
    case ModelSpec.provider(model) do
      "ixway" ->
        get(config, "ixway", %{})["effort"]

      provider when is_binary(provider) ->
        get(config, "providers", %{}) |> Map.get(provider, %{}) |> Map.get("effort")

      nil ->
        nil
    end
  end

  @doc "Returns configured effort defaults by provider for interactive switching."
  @spec preferred_efforts(config :: t() | nil) :: %{optional(String.t()) => String.t()}
  def preferred_efforts(config) do
    efforts =
      for {provider, %{"effort" => effort}} <- get(config, "providers", %{}),
          into: %{},
          do: {provider, effort}

    case get(config, "ixway", %{})["effort"] do
      nil -> efforts
      effort -> Map.put(efforts, "ixway", effort)
    end
  end

  @doc "Resolves mutually exclusive inference routes and the new-session model."
  @spec inference(config :: t(), parsed :: keyword(), default_model :: String.t()) ::
          {:ok, keyword()} | {:error, String.t()}
  def inference(config, parsed, default_model) do
    # Blank counts as unset (`Lemieux.CLI.Options.env/1`): an empty
    # `LMX_ROUTER` was otherwise a router named "" and an empty
    # `LMX_IXWAY_URL` an Ixway route to nowhere, each refusing every command.
    env = [
      router: Options.env("LMX_ROUTER"),
      ixway: Options.env("LMX_IXWAY_URL"),
      base_url: Options.env("LMX_BASE_URL")
    ]

    ixway = get(config, "ixway", %{})

    with {:ok, flag_mode} <- mode(parsed),
         {:ok, mode} <- selected_mode(flag_mode, env, ixway),
         {:ok, route} <- route(mode, parsed, env, config, ixway) do
      model =
        parsed[:model] || Options.env("LMX_MODEL") ||
          file_model(mode, config, ixway, default_model)

      {:ok, Keyword.put(route, :model, model)}
    end
  end

  defp mode(options) do
    mode(options[:router], options[:ixway], options[:base_url])
  end

  defp mode(router, _ixway, _base_url) when router not in [nil, "direct", "ixway"],
    do: {:error, "--router/LMX_ROUTER must be direct or ixway."}

  defp mode(_router, ixway, base_url) when not is_nil(ixway) and not is_nil(base_url),
    do:
      {:error,
       "Ixway cannot be combined with --base-url/LMX_BASE_URL in the same configuration layer."}

  defp mode("direct", ixway, _base_url) when not is_nil(ixway),
    do:
      {:error,
       "Direct routing cannot be combined with an Ixway URL in the same configuration layer."}

  defp mode("ixway", _ixway, base_url) when not is_nil(base_url),
    do:
      {:error,
       "Ixway cannot be combined with a provider base URL in the same configuration layer."}

  defp mode(router, _ixway, _base_url) when is_binary(router), do: {:ok, router}
  defp mode(nil, ixway, _base_url) when is_binary(ixway), do: {:ok, "ixway"}
  defp mode(nil, nil, base_url) when is_binary(base_url), do: {:ok, "direct"}
  defp mode(nil, nil, nil), do: {:ok, nil}

  defp selected_mode(nil, env, ixway) do
    with {:ok, env_mode} <- mode(env),
         do: {:ok, env_mode || if(ixway["enabled"] == true, do: "ixway", else: "direct")}
  end

  defp selected_mode(flag_mode, _env, _ixway), do: {:ok, flag_mode}

  defp route("ixway", parsed, env, _config, ixway) do
    endpoint = parsed[:ixway] || env[:ixway] || ixway["endpoint"]

    if Ixway.valid_endpoint?(endpoint),
      do: {:ok, [ixway: endpoint, base_url: nil]},
      else:
        {:error,
         "Ixway requires an http(s) instance origin without /v1, credentials, query or fragment."}
  end

  defp route("direct", parsed, env, config, _ixway) do
    url = parsed[:base_url] || env[:base_url] || get(config, "base_url")

    if is_nil(url) or valid_base_url?(url),
      do: {:ok, [ixway: nil, base_url: url]},
      else: {:error, "--base-url wants an absolute http:// or https:// URL"}
  end

  defp file_model("ixway", config, ixway, _default),
    do: ixway["model"] || ixway_file_model(get(config, "model"))

  defp file_model("direct", config, _ixway, default), do: direct_model(config) || default

  # The starter's direct model must not prevent a later --ixway opt-in from
  # selecting the gateway's advertised default. Explicit flag/env models still
  # pass through validation and report a mismatched namespace.
  defp ixway_file_model("ixway:" <> _id = model), do: model
  defp ixway_file_model(_direct_or_absent), do: "ixway:@default"

  defp decode(content) do
    case JSON.decode(content) do
      {:ok, settings} when is_map(settings) -> {:ok, settings}
      _ -> {:error, "lmx configuration must be a valid JSON object."}
    end
  end

  # Unknown top-level fields become warnings, except the two kinds the module
  # documentation says must fail. What is returned has them removed, so every
  # later check reads only fields it knows.
  defp without_unknown(settings) do
    unknown = settings |> Map.keys() |> Enum.reject(&(&1 in @fields)) |> Enum.sort()

    case Enum.find_value(unknown, &refused_field/1) do
      nil ->
        warnings =
          Enum.map(unknown, fn key ->
            "Unknown field #{inspect(key)} in the lmx config#{suggestion(key, @fields)}; it is ignored."
          end)

        {:ok, Map.drop(settings, unknown), warnings}

      message ->
        {:error, message}
    end
  end

  # The module documentation's "An empty key is a placeholder": every
  # `api_key` that is an empty or blank string, wherever the file keeps one,
  # becomes a warning naming its path and leaves the settings. Only the four
  # places the runtime reads a key from are looked at, and only when the
  # section around it is the object it should be; a section that is not is
  # left for `validate/1` to name.
  defp without_empty_keys(settings, warnings) do
    Enum.reduce(empty_key_paths(settings), {settings, warnings}, fn path, {settings, warnings} ->
      warning =
        "Empty field #{inspect(Enum.join(path, "."))} in the lmx config; it is ignored. " <>
          "Supply the key there, or remove the placeholder."

      {drop_path(settings, path), warnings ++ [warning]}
    end)
  end

  defp empty_key_paths(settings) do
    settings
    |> Enum.flat_map(fn
      {section, %{"api_key" => key}} when section in ~w(ixway jev_compaction) ->
        [{[section, "api_key"], key}]

      {section, providers}
      when section in ~w(providers web_search_providers) and is_map(providers) ->
        for {name, %{"api_key" => key}} <- providers, do: {[section, name, "api_key"], key}

      _other ->
        []
    end)
    |> Enum.filter(fn {_path, key} -> is_binary(key) and String.trim(key) == "" end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.sort()
  end

  defp drop_path(settings, path) do
    {parents, [key]} = Enum.split(path, -1)
    update_in(settings, parents, &Map.delete(&1, key))
  end

  defp refused_field(key) do
    case Map.fetch(@retired_fields, key) do
      {:ok, moved} ->
        "Unknown field #{inspect(key)} in the lmx config: #{moved}."

      :error ->
        case closest(key, @fields) do
          routing when routing in @routing_fields ->
            "Unknown field #{inspect(key)} in the lmx config (did you mean #{inspect(routing)}?). " <>
              "It is refused rather than ignored because it could change where requests go."

          _other ->
            nil
        end
    end
  end

  @doc false
  @spec suggestion(key :: String.t(), known :: [String.t()]) :: String.t()
  def suggestion(key, known) do
    case closest(key, known) do
      nil -> ""
      match -> " (did you mean #{inspect(match)}?)"
    end
  end

  # Jaro distance over the known names; below this, a guess is noise.
  defp closest(key, known) when is_binary(key) do
    known
    |> Enum.map(&{&1, String.jaro_distance(key, &1)})
    |> Enum.max_by(&elem(&1, 1), fn -> {nil, 0.0} end)
    |> then(fn
      {match, score} when score >= 0.82 -> match
      _far -> nil
    end)
  end

  defp closest(_key, _known), do: nil

  defp validate(settings) do
    with :ok <- validate_fields(settings),
         :ok <- A2AExtension.validate(Map.get(settings, "a2a_peers", %{})),
         :ok <- validate_providers(Map.get(settings, "providers", %{})),
         :ok <- validate_extensions(Map.get(settings, "extensions", [])),
         :ok <- validate_disabled_extensions(Map.get(settings, "disabled_extensions", [])),
         :ok <- validate_themes(settings),
         :ok <- validate_key_map(settings),
         :ok <- validate_section(settings, "permissions", @permission_fields),
         :ok <- validate_section(settings, "sandbox", @sandbox_fields),
         :ok <- validate_section(settings, "verify", @verify_fields),
         :ok <- validate_skills(Map.get(settings, "skills", %{})),
         :ok <- validate_mcp_servers(Map.get(settings, "mcp_servers", %{})),
         :ok <- validate_extension_options(Map.get(settings, "extension_options", %{})),
         :ok <- validate_web_search_providers(Map.get(settings, "web_search_providers", %{})),
         :ok <- validate_ixway(Map.get(settings, "ixway", %{})) do
      validate_jev(Map.get(settings, "jev_compaction", %{}))
    end
  end

  # `"sandbox"` and `"verify"` also take a bare boolean; only their object
  # form has keys to check.
  defp validate_section(settings, section, allowed) do
    case Map.get(settings, section) do
      fields when is_map(fields) -> validate_section_fields(fields, section, allowed)
      _absent_or_boolean -> :ok
    end
  end

  defp validate_section_fields(fields, section, allowed) do
    with :ok <- known_fields(fields, allowed, "#{section} section") do
      if Enum.all?(fields, &valid_section_entry?(section, &1)),
        do: :ok,
        else: {:error, "Invalid lmx #{section} setting."}
    end
  end

  defp valid_section_entry?("permissions", {"mode", mode}), do: mode in @permission_modes

  defp valid_section_entry?("permissions", {key, rules}) when key in ~w(allow deny ask),
    do: is_list(rules) and Enum.all?(rules, &(is_binary(&1) and &1 != ""))

  defp valid_section_entry?("permissions", {"non_interactive", value}),
    do: value in ~w(deny allow)

  defp valid_section_entry?(section, {"enabled", value}) when section in ~w(sandbox verify),
    do: is_boolean(value)

  defp valid_section_entry?("sandbox", {"backend", value}),
    do: value in ~w(auto seatbelt bubblewrap)

  defp valid_section_entry?("sandbox", {key, value}) when key in ~w(network localhost),
    do: is_boolean(value)

  defp valid_section_entry?("sandbox", {key, paths}) when key in ~w(writable hidden),
    do: is_list(paths) and Enum.all?(paths, &(is_binary(&1) and &1 != ""))

  defp valid_section_entry?("verify", {"command", value}),
    do: is_binary(value) and String.trim(value) != ""

  defp valid_section_entry?("verify", {"max_continuations", value}),
    do: is_integer(value) and value >= 0 and value <= 5

  defp valid_section_entry?("verify", {"timeout_ms", value}),
    do: is_integer(value) and value > 0

  defp valid_section_entry?(_section, _entry), do: false

  # `"skills": {"omarchy": false, "disabled": ["diagnose-crash", "plugin:name"]}`
  # (`Lemieux.CLI.Skills`, `Lemieux.CLI.SystemSkills`). A name is checked for
  # its shape — a skill name, or a plugin's `namespace:name` — not for
  # existence: a skill that is not installed today may be tomorrow, and the
  # point of the list is that it stays out when it is.
  defp validate_skills(skills) do
    with :ok <- known_fields(skills, @skills_fields, "skills section") do
      if Enum.all?(skills, &valid_skills_entry?/1),
        do: :ok,
        else:
          {:error,
           ~s(Invalid lmx skills setting: "omarchy" is true or false, and "disabled" a ) <>
             ~s(list of skill names such as "diagnose-crash" or "plugin:name".)}
    end
  end

  defp valid_skills_entry?({"omarchy", value}), do: is_boolean(value)

  defp valid_skills_entry?({"disabled", names}),
    do:
      is_list(names) and
        Enum.all?(names, &(is_binary(&1) and Regex.match?(~r/\A(?:[^\s:]+:)?[a-z0-9-]+\z/, &1)))

  # The personal servers, in the shape `.mcp.json` and Claude Code use: an
  # object of names to server objects. What each server says is checked by
  # `Lemieux.MCP` when it connects, like any other configuration file.
  defp validate_mcp_servers(servers) do
    if Enum.all?(servers, fn {name, server} -> valid_server_name?(name) and is_map(server) end),
      do: :ok,
      else:
        {:error,
         "Invalid lmx config field: mcp_servers. It is an object of server names " <>
           "(letters, digits, - and _) to server objects, as in .mcp.json."}
  end

  defp valid_server_name?(name),
    do: is_binary(name) and Regex.match?(~r/^[A-Za-z0-9][A-Za-z0-9_-]*$/, name)

  defp validate_extension_options(options) do
    if Enum.all?(options, fn {name, value} -> Extensions.valid_name?(name) and is_map(value) end),
      do: :ok,
      else:
        {:error,
         "Invalid lmx config field: extension_options. It maps an extension's name " <>
           "to a JSON object of its options."}
  end

  defp validate_extensions(names) do
    if Enum.all?(names, &Extensions.valid_name?/1),
      do: :ok,
      else:
        {:error,
         "Invalid lmx config field: extensions. Each entry is the name of a directory under " <>
           "#{Extensions.default_root()} (letters, digits, - and _), never a path or a module."}
  end

  defp validate_disabled_extensions(names) do
    if Enum.all?(names, &(&1 in @shipped_extensions)) and
         length(Enum.uniq(names)) == length(names),
       do: :ok,
       else:
         {:error,
          "Invalid lmx config field: disabled_extensions. Use unique shipped names: #{Enum.join(@shipped_extensions, ", ")}."}
  end

  # The registry is built here, once, for the cross-field check: a `"theme"`
  # is valid if the screen will have it, and the screen has the shipped three
  # plus whatever `"themes"` registered. Every problem in every theme comes
  # back in one sentence, so the file is fixed in one pass.
  defp validate_themes(settings) do
    case Theme.registry(Map.get(settings, "themes", %{})) do
      {:ok, registry} ->
        validate_theme(Map.get(settings, "theme"), registry)

      {:error, problems} ->
        {:error, "Invalid lmx config field: themes. #{Enum.join(problems, "; ")}."}
    end
  end

  # Read once here, for the same reason `"themes"` is: a binding the screen
  # cannot use would otherwise be found when it opens, over a covered standard
  # error. Every problem — a key that does not parse, an action that does not
  # exist, two spellings of one key that disagree, `interrupt` left with no
  # key — comes back in one sentence. The map itself is what goes on the
  # harness; `Lemieux.TUI` reads it again when the screen opens.
  defp validate_key_map(%{"keys" => keys}) do
    case Keys.from_map(keys) do
      {:ok, _keys} ->
        :ok

      {:error, problems} ->
        {:error, "Invalid lmx config field: keys. #{Enum.join(problems, "; ")}."}
    end
  end

  defp validate_key_map(_settings), do: :ok

  defp validate_theme(nil, _registry), do: :ok

  defp validate_theme(name, registry) do
    case Theme.named(name, registry) do
      {:ok, _theme} ->
        :ok

      :error ->
        {:error,
         "Invalid lmx config field: theme. #{inspect(name)} is not a palette the screen has; " <>
           "it has #{Enum.join(Theme.names(registry), ", ")}."}
    end
  end

  defp known_fields(settings, allowed, label) do
    case settings |> Map.keys() |> Enum.reject(&(&1 in allowed)) |> Enum.sort() do
      [] ->
        :ok

      [key | _rest] ->
        {:error, "Unknown field #{inspect(key)} in lmx #{label}#{suggestion(key, allowed)}."}
    end
  end

  defp validate_fields(settings) do
    Enum.reduce_while(settings, :ok, fn {key, value}, :ok ->
      if valid_field?(key, value),
        do: {:cont, :ok},
        else: {:halt, {:error, "Invalid lmx config field: #{key}."}}
    end)
  end

  defp valid_field?("a2a_peers", value), do: is_map(value)

  defp valid_field?("version", value), do: value == 1

  defp valid_field?(key, value) when key in ~w(max_turns max_requests),
    do: is_integer(value) and value > 0

  defp valid_field?("max_cost_usd", value), do: is_number(value) and value >= 0
  defp valid_field?("model", value), do: valid_model?(value)
  defp valid_field?("context_window", value), do: is_integer(value) and value > 0
  defp valid_field?("auto_compaction", value), do: is_boolean(value)
  defp valid_field?("keep_recent_tokens", value), do: is_integer(value) and value > 0
  defp valid_field?("summary_model", value), do: valid_model?(value)
  defp valid_field?("compaction_price_tiers", value), do: valid_price_tiers?(value)
  defp valid_field?("jev_compaction", value), do: is_map(value)
  defp valid_field?("base_url", value), do: valid_base_url?(value)
  defp valid_field?("web_search", value), do: value in ["brave", "none"]
  # What each section holds is checked after the field pass, naming the
  # section and key: see `validate_web_search_providers/1`.
  defp valid_field?("web_search_providers", value), do: is_map(value)
  defp valid_field?("web_fetch", value), do: is_boolean(value)
  defp valid_field?("mouse", value), do: is_boolean(value)
  defp valid_field?("project_mcp", value), do: is_boolean(value)
  defp valid_field?("delegate", value), do: is_boolean(value)
  # Whether the name is a palette is decided after the field pass, once
  # `"themes"` has been read: see `validate_themes/1`.
  defp valid_field?("theme", value), do: is_binary(value) and value != ""
  defp valid_field?("themes", value), do: is_map(value)
  # What the map says is checked after the field pass: see `validate_key_map/1`.
  defp valid_field?("keys", value), do: is_map(value)
  defp valid_field?("extensions", value), do: is_list(value)
  defp valid_field?("disabled_extensions", value), do: is_list(value)
  defp valid_field?("scrub_credentials", value), do: is_boolean(value)
  defp valid_field?("notifications", value), do: is_boolean(value)
  # What the object holds is checked after the field pass: `validate_skills/1`.
  defp valid_field?("skills", value), do: is_map(value)

  defp valid_field?("credential_allowlist", value),
    do: is_list(value) and Enum.all?(value, &valid_env_pattern?/1)

  # What the object holds is read by `Lemieux.Hooks.Config.load/2` when the
  # session is prepared, where every problem is named.
  defp valid_field?("hooks", value), do: is_map(value)
  defp valid_field?("permissions", value), do: is_map(value)

  defp valid_field?(key, value) when key in ~w(sandbox verify),
    do: is_boolean(value) or is_map(value)

  defp valid_field?("mcp_servers", value), do: is_map(value)
  defp valid_field?("mcp_discovery", value), do: value in ~w(auto on off)
  defp valid_field?("extension_options", value), do: is_map(value)
  defp valid_field?("scout_model", value), do: valid_model?(value)

  defp valid_field?("input_modalities", value),
    do: is_list(value) and value != [] and Enum.all?(value, &Map.has_key?(@modalities, &1))

  defp valid_field?(key, value) when key in ~w(plugin_dirs marketplaces plugins),
    do: is_list(value) and Enum.all?(value, &(is_binary(&1) and String.trim(&1) != ""))

  # The labels the status line calls a running turn, replacing the shipped list
  # rather than adding to it. Checked here rather than shrugged at while drawing: a
  # label too long for the row pushes the measured half of the line off the edge,
  # and a setting silently ignored when it is wrong is one nobody can debug.
  defp valid_field?("processing", value), do: Processing.valid?(value)

  defp valid_field?(key, value) when key in ["system", "sessions_dir"],
    do: is_binary(value) and value != ""

  defp valid_field?(key, value) when key in ["providers", "ixway"],
    do: is_map(value)

  defp valid_price_tiers?(prices) when is_map(prices) do
    Enum.all?(prices, fn {model, bands} ->
      valid_model?(model) and is_list(bands) and bands != [] and
        Enum.all?(bands, &valid_price_band?/1) and ordered_price_bands?(bands)
    end)
  end

  defp valid_price_tiers?(_prices), do: false

  defp valid_price_band?(band) when is_map(band) do
    Enum.all?(Map.keys(band), &(&1 in @price_fields)) and
      Map.has_key?(band, "up_to") and
      (is_nil(band["up_to"]) or (is_integer(band["up_to"]) and band["up_to"] > 0)) and
      valid_rate?(band["input_per_million"]) and
      valid_rate?(band["output_per_million"]) and
      (not Map.has_key?(band, "cached_input_per_million") or
         valid_rate?(band["cached_input_per_million"]))
  end

  defp valid_price_band?(_band), do: false

  defp ordered_price_bands?(bands) do
    limits = Enum.map(bands, & &1["up_to"])
    finite = Enum.filter(limits, &is_integer/1)

    List.last(limits) == nil and length(finite) == length(limits) - 1 and
      finite == Enum.sort(Enum.uniq(finite))
  end

  defp valid_rate?(value), do: is_number(value) and value >= 0

  # The four sections that hold credentials are checked key by key, so the
  # sentence names the field and what it takes (the module documentation's
  # "Unknown fields are named"). Each `*_field/2` returns `:ok` or the
  # expectation for one key; `each_field/3` turns the first miss into the
  # sentence. The keys themselves were checked by `known_fields/3` first, so
  # no clause needs a fallback.
  @key_expectation "A key is one line of text."
  @endpoint_expectation "It must be an http(s) origin without /v1, credentials, query or fragment."
  @effort_expectation "It must be a lowercase name such as low, medium or high."

  defp validate_web_search_providers(providers) do
    Enum.reduce_while(providers, :ok, fn {name, settings}, :ok ->
      case validate_web_search_provider(name, settings) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The name is not echoed: what sits in a key's place in a mistyped file
  # may be the key.
  defp validate_web_search_provider(name, settings) do
    with :ok <-
           expect(
             is_binary(name) and Regex.match?(~r/^[a-z][a-z0-9_]*$/, name),
             "web_search_providers",
             "A search provider's name is lowercase letters, digits and underscores."
           ),
         :ok <- object(settings, "web_search_providers.#{name}"),
         :ok <- known_fields(settings, ["api_key"], "web_search_providers.#{name} section") do
      each_field(settings, "web_search_providers.#{name}", fn "api_key", key ->
        expect(key_text?(key), @key_expectation)
      end)
    end
  end

  defp validate_providers(providers) do
    Enum.reduce_while(providers, :ok, fn {provider, settings}, :ok ->
      case validate_provider(provider, settings) do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp validate_provider(provider, settings) do
    with :ok <- validate_provider_name(provider),
         :ok <- object(settings, "providers.#{provider}"),
         :ok <- known_fields(settings, @provider_fields, "providers.#{provider} section") do
      each_field(settings, "providers.#{provider}", &provider_field(provider, &1, &2))
    end
  end

  defp validate_provider_name(provider) do
    if valid_provider_name?(provider),
      do: :ok,
      else: {:error, "Invalid lmx provider name."}
  end

  defp valid_provider_name?(name),
    do: is_binary(name) and name != "ixway" and Regex.match?(~r/^[a-z][a-z0-9_]*$/, name)

  defp provider_field(_provider, "api_key", key), do: expect(key_text?(key), @key_expectation)

  defp provider_field(provider, "model", model),
    do:
      expect(
        valid_model?(model) and ModelSpec.provider(model) == provider,
        "It must be a model specification for that provider (#{provider}:MODEL)."
      )

  defp provider_field(_provider, "effort", effort),
    do: expect(valid_effort?(effort), @effort_expectation)

  defp valid_effort?(value),
    do: is_binary(value) and Regex.match?(~r/^[a-z][a-z0-9_-]*$/, value)

  defp validate_ixway(ixway) do
    with :ok <- known_fields(ixway, @ixway_fields, "ixway section") do
      each_field(ixway, "ixway", &ixway_field/2)
    end
  end

  defp ixway_field("enabled", value), do: expect(is_boolean(value), "It must be true or false.")

  defp ixway_field("endpoint", value),
    do: expect(Ixway.valid_endpoint?(value), @endpoint_expectation)

  defp ixway_field("api_key", value), do: expect(key_text?(value), @key_expectation)

  defp ixway_field("model", value),
    do:
      expect(
        match?("ixway:" <> id when id != "", value),
        "It must name a gateway model as ixway:ID."
      )

  defp ixway_field("effort", value), do: expect(valid_effort?(value), @effort_expectation)

  defp ixway_field("headers", value),
    do: expect(valid_headers?(value), "It must be an object of header names to values.")

  defp valid_headers?(headers) when is_map(headers) do
    _connection = Ixway.new(endpoint: "http://localhost", headers: Map.to_list(headers))
    true
  rescue
    ArgumentError -> false
  end

  defp valid_headers?(_value), do: false

  defp validate_jev(jev) do
    with :ok <- known_fields(jev, @jev_fields, "jev_compaction section"),
         :ok <- each_field(jev, "jev_compaction", &jev_field/2) do
      jev_budget(jev)
    end
  end

  defp jev_field("mode", value),
    do: expect(value in ~w(auto apply shadow off), "It must be auto, apply, shadow or off.")

  defp jev_field("route", value),
    do: expect(value in ~w(auto ixway typesafe), "It must be auto, ixway or typesafe.")

  defp jev_field("model", value),
    do: expect(is_binary(value) and value != "", "It must name a model.")

  defp jev_field("endpoint", value),
    do: expect(Ixway.valid_endpoint?(value), @endpoint_expectation)

  defp jev_field("api_key", value), do: expect(key_text?(value), @key_expectation)

  defp jev_field("max_evaluations", value),
    do: expect(is_integer(value) and value > 0, "It must be a whole number above zero.")

  defp jev_field(key, value)
       when key in ~w(max_cost_usd reservation_per_call_usd input_per_million output_per_million),
       do: expect(is_number(value) and value >= 0, "It must be a number, zero or more.")

  defp jev_budget(%{"max_cost_usd" => cap} = jev) do
    reservation = jev["reservation_per_call_usd"]

    expect(
      is_number(reservation) and reservation > 0 and reservation <= cap,
      "jev_compaction.reservation_per_call_usd",
      "With max_cost_usd set, it must be a number above zero and no more than max_cost_usd."
    )
  end

  defp jev_budget(_jev), do: :ok

  defp each_field(settings, path, check) do
    Enum.reduce_while(settings, :ok, fn {key, value}, :ok ->
      case check.(key, value) do
        :ok -> {:cont, :ok}
        {:error, expectation} -> {:halt, invalid("#{path}.#{key}", expectation)}
      end
    end)
  end

  defp expect(true, _expectation), do: :ok
  defp expect(false, expectation), do: {:error, expectation}

  defp expect(true, _path, _expectation), do: :ok
  defp expect(false, path, expectation), do: invalid(path, expectation)

  defp invalid(path, expectation),
    do: {:error, "Invalid lmx config field: #{path}. #{expectation}"}

  defp object(settings, _path) when is_map(settings), do: :ok
  defp object(_settings, path), do: invalid(path, "It must be an object.")

  # An environment variable name, or one with `*` wildcards (`NPM_*`).
  defp valid_env_pattern?(value),
    do: is_binary(value) and Regex.match?(~r/^[A-Za-z_*][A-Za-z0-9_*]*$/, value)

  # What a key field may hold: one line of text, the empty line included,
  # since `without_empty_keys/2` reads that as a placeholder. What may be
  # saved as a key is `valid_key?/1`, which also wants something in it.
  defp key_text?(value), do: is_binary(value) and not String.contains?(value, ["\r", "\n"])

  defp valid_key?(value), do: key_text?(value) and String.trim(value) != ""

  defp valid_model?(value) when is_binary(value), do: match?({:ok, _}, ModelSpec.split(value))
  defp valid_model?(_value), do: false

  defp valid_base_url?(url) when is_binary(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host}}
      when scheme in ["http", "https"] and is_binary(host) and host != "" ->
        true

      _ ->
        false
    end
  end

  defp valid_base_url?(_url), do: false

  defp permissions(stat, settings) do
    secrets? =
      section_has_keys?(settings, "providers") or
        section_has_keys?(settings, "web_search_providers") or
        get_in(settings, ["ixway", "api_key"]) != nil or
        get_in(settings, ["jev_compaction", "api_key"]) != nil

    check_mode(:os.type(), stat.mode, secrets?)
  end

  @doc false
  # Windows has no POSIX modes: Erlang reports every writable file there as
  # 0666, so this check refused every configuration on Windows, the default
  # one lmx had just created included (found in the launch review, 2026-10).
  # There the profile directory's ACLs are what keep the file private.
  @spec check_mode(os :: {atom(), atom()}, mode :: non_neg_integer(), secrets? :: boolean()) ::
          :ok | {:error, String.t()}
  def check_mode({:win32, _name}, _mode, _secrets?), do: :ok

  def check_mode(_unix, mode, secrets?) do
    mask = if secrets?, do: 0o077, else: 0o022

    if Bitwise.band(mode, mask) == 0,
      do: :ok,
      else:
        {:error, "lmx config permissions are too open. Run chmod 600 on the configuration file."}
  end

  defp section_has_keys?(settings, section) do
    Enum.any?(Map.get(settings, section, %{}), fn {_name, fields} ->
      Map.has_key?(fields, "api_key")
    end)
  end

  defp regular_file(%{type: :regular}), do: :ok
  defp regular_file(_stat), do: {:error, "lmx configuration must be a regular file."}

  defp missing_file(options) do
    if Keyword.get(options, :optional, false),
      do: {:ok, %__MODULE__{}},
      else: {:error, "The selected lmx configuration file does not exist."}
  end
end
