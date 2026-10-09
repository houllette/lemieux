defmodule Lemieux.Harness do
  @moduledoc """
  Every seam's current setting, in one value an extension can read and write.

  `Lemieux.Session.start_link/1` takes its behaviour as a keyword list, and a
  host that writes that list by hand needs nothing more. What a keyword list
  cannot do is be handed to somebody else's code to be *changed*: an
  extension that wants to wrap `bash` has to find the catalog, an extension
  that wants one more hook has to find the hooks, and a keyword list with
  duplicate keys and absent defaults makes both a guess. This struct is the
  same options as fields, one for one, with the same names, so that
  `c:Lemieux.Extension.apply/2` has a fixed shape to read and a fixed shape to
  return, and `session_options/1` turns the result back into the keyword the
  session already accepts. Nothing in the loop reads the struct; it is a way
  of arriving at the options, not a second configuration language.

  ## Example

  A harness starts from the fields a host sets and passes through the
  extensions it chooses, in order, recording each one:

      iex> {:ok, harness} =
      ...>   Lemieux.Harness.assemble(Lemieux.Harness.new(max_turns: 20), [
      ...>     Lemieux.Extensions.Search
      ...>   ])
      iex> Enum.map(harness.tools, &Lemieux.Tool.name/1)
      ["read", "grep", "glob", "write", "edit", "bash"]
      iex> Enum.map(harness.applied, & &1["module"])
      ["Lemieux.Extensions.Search"]

  A session takes it as `:harness`, beside the host authority the harness
  deliberately does not hold:

      Lemieux.start_session(
        harness: harness,
        supervisor: MyApp.Agents,
        provider: Lemieux.Providers.ReqLLM.new(),
        store: Lemieux.Store.JSONL.new("sessions"),
        model: "anthropic:claude-sonnet-5"
      )

  ## What is here and what is not

  The fields are the session's options, plus the handful of opinions a host
  with a screen reads (`theme`, `themes`, `keys`, `layout`, `status_line`,
  `followups`, `processing`, `skills`, `notices`, `workspace`, `commands`
  and `renderers`), plus `applied`, the provenance `assemble/2` records.
  `themes` is the palettes a sitting can switch between beyond the shipped
  three, in `Lemieux.TUI.Theme`'s map form or as structs; `theme` names the
  one it starts in. `keys` is the key map `Lemieux.TUI.Keys` reads — a
  module, or the string-keyed map the config file's `"keys"` carries, from
  key description to action name — and `layout` is the module that places
  the screen's regions. Every one of them left `nil` means the screen's own
  default, the same rule `theme` has always had.

  Provider, store, model, supervisor, subscriber, id and working directory
  are deliberately **not** fields. They are host authority — where the
  session runs, who pays, which transcript it is — and the rule for them is
  already that they are never recorded and never restored. Putting them
  in the composition value would make accidental redirection easy. This is
  an API boundary, not isolation: an extension is trusted Elixir executing
  in the host VM. Explicit options beside `harness:` win over its fields.
  The CLI also reapplies explicit host constraints after extension assembly.

  ## Unset means the session's own default

  A field left `nil` is omitted from `session_options/1`, so the session
  applies whatever default it applies when the option is absent: the
  default prompt, `Lemieux.Tools.default/0`, no budget, the recorded value
  on a resume. Three fields use `:default` for absence because `nil` has a
  meaning: `system: nil` disables the prompt, `compact_at: nil` disables
  threshold compaction, and `reasoning_effort: nil` clears a recorded effort.
  An extension can therefore express these choices without losing them in
  conversion to session options.

  ## Resume

  A resumed session takes its prompt and catalog from the transcript when
  the harness leaves them unset. An extension that composes over them — the
  workspace layer over the recorded prompt, a scout beside the recorded
  tools — needs them present, so a host that resumes reads the transcript
  first and reconstructs the inputs before assembling. Reapplying a wrapper
  to its own output stacks wrappers, while recording only module tools loses
  wrappers altogether. `Lemieux.CLI.Runtime` keeps an inert reconstruction
  record and reapplies currently selected extensions to the original inputs.
  Library hosts own this policy; this struct does not load code or restore
  executable state from a transcript.
  """

  alias Lemieux.Harness.Explanation
  alias Lemieux.Harness.Validation
  alias Lemieux.Prompt
  alias Lemieux.Tool
  alias Lemieux.Tools

  @typedoc """
  What `assemble/2` records for each extension it applied, in order: the
  module, the digest of its compiled code, and what its `describe/1` said.
  JSON-shaped so it can go into the harness snapshot as it is.
  """
  @type applied :: %{
          required(String.t()) => String.t() | map()
        }

  @type t :: %__MODULE__{
          system: String.t() | nil | :default,
          tools: [Tool.t()] | nil,
          host_tools: [Tool.t()] | nil,
          disabled_tools: [String.t()] | nil,
          tool_profile: term(),
          hooks: Lemieux.Hooks.t() | nil,
          compaction: module() | {module(), term()} | nil,
          messages: module() | nil,
          guard: module() | {module(), term()} | nil,
          environment: Lemieux.Environment.t() | nil,
          mcp_servers: [map()] | nil,
          mcp_transports: %{optional(String.t()) => module()} | nil,
          mcp_auth: term(),
          mcp_stdio_launcher: (... -> term()) | nil,
          provider_retry: keyword() | false | nil,
          max_turns: pos_integer() | nil,
          max_cost_usd: number() | nil,
          max_requests: pos_integer() | nil,
          tool_timeout_ms: pos_integer() | nil,
          tool_output_bytes: pos_integer() | nil,
          approval_timeout: pos_integer() | nil,
          context_window: pos_integer() | nil,
          auto_compaction: boolean() | nil,
          compact_at: number() | nil | :default,
          input_token_counter: (Lemieux.Request.t() -> {:ok, pos_integer()} | :unknown) | nil,
          keep: number() | nil,
          keep_recent_tokens: pos_integer() | nil,
          keep_attachments: non_neg_integer() | :all | nil,
          summary_sections: boolean() | nil,
          summary_model: String.t() | nil,
          summary_params: keyword() | nil,
          summary_max_bytes: pos_integer() | nil,
          compaction_price_tiers: map() | nil,
          compaction_expected_output_tokens: non_neg_integer() | nil,
          compaction_minimum_savings_usd: number() | nil,
          params: keyword() | nil,
          reasoning_effort: String.t() | nil | :default,
          output_schema: term(),
          harness_context: map() | nil,
          correlation_ids: term(),
          tool_token_counter: (... -> term()) | nil,
          provider_limit_key: term(),
          theme: term(),
          themes: %{optional(String.t()) => term()},
          keys: module() | %{optional(String.t()) => String.t()} | nil,
          layout: module() | nil,
          status_line: module() | nil,
          followups: module() | nil,
          processing: [String.t()] | nil,
          startup_animation: map() | false | nil,
          skills: list(),
          notices: [String.t()],
          workspace: term(),
          commands: list(),
          renderers: map(),
          applied: [applied()]
        }

  # The session's options, in the order `Lemieux.Session.start_link/1`
  # documents them. `session_options/1` walks this list, so a field added here
  # without a session option of the same name would be passed to a session
  # that ignores it; keep the two in step.
  @session_fields ~w(system tools host_tools disabled_tools tool_profile hooks compaction messages
                     guard environment mcp_servers mcp_transports mcp_auth mcp_stdio_launcher
                     provider_retry max_turns max_cost_usd max_requests tool_timeout_ms
                     tool_output_bytes approval_timeout context_window auto_compaction compact_at
                     input_token_counter keep
                     keep_recent_tokens
                     keep_attachments summary_sections summary_model summary_params
                     summary_max_bytes compaction_price_tiers
                     compaction_expected_output_tokens compaction_minimum_savings_usd
                     params reasoning_effort output_schema
                     harness_context correlation_ids tool_token_counter provider_limit_key)a

  @host_fields ~w(theme themes keys layout status_line followups processing startup_animation skills notices
                  workspace commands renderers)a

  defstruct Enum.map(@session_fields -- [:system, :compact_at, :reasoning_effort], &{&1, nil}) ++
              [
                system: :default,
                compact_at: :default,
                reasoning_effort: :default,
                theme: nil,
                themes: %{},
                keys: nil,
                layout: nil,
                status_line: nil,
                followups: nil,
                processing: nil,
                startup_animation: nil,
                skills: [],
                notices: [],
                workspace: nil,
                commands: [],
                renderers: %{},
                applied: []
              ]

  @doc """
  A harness with the given fields set and everything else unset.

  A key that is not a field raises, the way a misspelled session option
  would not: the session ignores keys it does not know, and an opinion that
  silently fails to apply is the bug this struct exists to prevent.
  """
  @spec new(fields :: keyword()) :: t()
  def new(fields \\ []) when is_list(fields), do: struct!(__MODULE__, fields)

  @doc "The fields that are session options, in the session's own order."
  @spec session_fields() :: [atom()]
  def session_fields, do: @session_fields

  @doc "The fields only a host with a screen reads."
  @spec host_fields() :: [atom()]
  def host_fields, do: @host_fields

  @doc """
  Explains preparation without exposing prompts, initialization options,
  hook functions, credentials or host state. `overrides` are final session
  options; their field names are shown beside the resulting settings.

  This is the local catalog after profile filtering, before MCP discovery
  and request hooks. Unset settings are labelled `session_default`; this
  report does not claim that a provider request has been authorized or sent.
  """
  @spec explain(harness :: t(), overrides :: keyword()) :: map()
  def explain(%__MODULE__{} = harness, overrides \\ []),
    do: Explanation.build(harness, overrides)

  @doc "Returns changed top-level fields between two explanation reports."
  @spec diff(before :: map(), current :: map()) :: map()
  def diff(before, current) do
    (Map.keys(before) ++ Map.keys(current))
    |> Enum.uniq()
    |> Enum.reject(&(Map.get(before, &1) == Map.get(current, &1)))
    |> Map.new(&{&1, %{"before" => Map.get(before, &1), "after" => Map.get(current, &1)}})
  end

  @doc """
  The keyword list `Lemieux.Session.start_link/1` accepts for this harness.

  Unset fields are omitted (see the module documentation for what that
  means), and `applied` is folded into
  `harness_context["extensions"]["applied"]`, beside the `"session_profile"`
  key a profile writes there, so the per-request harness snapshot records
  which extensions shaped the session. Host fields are not session options
  and do not appear.
  """
  @spec session_options(harness :: t()) :: keyword()
  def session_options(%__MODULE__{} = harness) do
    harness = with_provenance(harness)

    Enum.flat_map(@session_fields, fn field ->
      value = Map.fetch!(harness, field)
      if set?(field, value), do: [{field, value}], else: []
    end)
  end

  # These fields distinguish an explicit nil from an absent option.
  defp set?(field, :default) when field in [:system, :compact_at, :reasoning_effort], do: false
  defp set?(field, _value) when field in [:system, :compact_at, :reasoning_effort], do: true
  defp set?(_field, nil), do: false
  defp set?(_field, _value), do: true

  defp with_provenance(%__MODULE__{applied: []} = harness), do: harness

  defp with_provenance(%__MODULE__{applied: applied} = harness) do
    update_harness_context(harness, fn context ->
      extensions = Map.get(context, "extensions", %{})
      Map.put(context, "extensions", Map.put(extensions, "applied", applied))
    end)
  end

  @doc """
  Applies `extensions` to `base`, left to right, recording each one.

  Each element is a module or `{module, opts}`; `opts` defaults to `[]`. A
  module's `c:Lemieux.Extension.init/1` turns the options into state when it
  has one, and the options are the state when it does not. Its
  `c:Lemieux.Extension.apply/2` then receives the harness the previous
  extension returned. A module that does not export `apply/2` is not an
  extension and the fold stops with `{:error, {module, :not_an_extension}}`;
  an `init/1` that returns `{:error, reason}` stops it with
  `{:error, {module, reason}}`, because a session started without the
  behaviour somebody named is worse than no session.

  An `apply/2` that returns something other than a harness raises. That is a
  bug in the extension, not a condition a host can handle, and a `{:error,
  _}` a host might rescue past would hide it.

  Provenance is `%{"module" => name, "digest" => hex, "options" => described}`
  per extension, appended to `applied` in application order — see
  `Lemieux.Extension` for why the order is the part worth recording.
  """
  @spec assemble(base :: t(), extensions :: [Lemieux.Extension.spec()]) ::
          {:ok, t()} | {:error, {module(), term()}}
  def assemble(%__MODULE__{} = base, extensions) when is_list(extensions) do
    Enum.reduce_while(extensions, {:ok, base}, fn extension, {:ok, harness} ->
      {module, opts} = normalize(extension)

      with :ok <- extension?(module),
           {:ok, state} <- init(module, opts) do
        updated = apply_extension(harness, module, state)
        {:cont, {:ok, record(updated, module, state, changed_fields(harness, updated))}}
      else
        {:error, reason} -> {:halt, {:error, {module, reason}}}
      end
    end)
  end

  defp normalize({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
  defp normalize(module) when is_atom(module), do: {module, []}

  defp normalize(other) do
    raise ArgumentError,
          "an extension is a module or {module, opts}; got #{inspect(other)}"
  end

  defp extension?(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :apply, 2),
      do: :ok,
      else: {:error, :not_an_extension}
  end

  defp init(module, opts) do
    if function_exported?(module, :init, 1) do
      case module.init(opts) do
        {:ok, state} ->
          {:ok, state}

        {:error, reason} ->
          {:error, reason}

        other ->
          raise ArgumentError,
                "#{inspect(module)}.init/1 must return {:ok, state} or {:error, reason}; " <>
                  "got #{inspect(other)}"
      end
    else
      {:ok, opts}
    end
  end

  defp apply_extension(harness, module, state) do
    case module.apply(harness, state) do
      %__MODULE__{} = applied ->
        applied

      other ->
        raise ArgumentError,
              "#{inspect(module)}.apply/2 must return a %Lemieux.Harness{}; got #{inspect(other)}"
    end
  end

  defp changed_fields(before, updated),
    do:
      Enum.filter(
        @session_fields ++ @host_fields,
        &(Map.fetch!(before, &1) != Map.fetch!(updated, &1))
      )
      |> Enum.map(&Atom.to_string/1)

  defp record(harness, module, state, changes) do
    entry = %{
      "module" => inspect(module),
      "digest" => module |> module_digest() |> Base.encode16(case: :lower),
      "options" => describe(module, state),
      "changes" => changes
    }

    %{harness | applied: harness.applied ++ [entry]}
  end

  # The md5 the compiler writes into the beam: two builds of the same source
  # share it, and any change to the module's code changes it, which is the
  # property a provenance record wants from a code digest.
  defp module_digest(module), do: module.module_info(:md5)

  defp describe(module, state) do
    if function_exported?(module, :describe, 1) do
      case module.describe(state) do
        %{} = description ->
          Validation.description!(description, module)

        other ->
          raise ArgumentError,
                "#{inspect(module)}.describe/1 must return a map; got #{inspect(other)}"
      end
    else
      %{}
    end
  end

  @doc "Replaces the catalog."
  @spec put_tools(harness :: t(), tools :: [Tool.t()]) :: t()
  def put_tools(%__MODULE__{} = harness, tools) when is_list(tools),
    do: %{harness | tools: tools}

  @doc """
  Transforms the catalog, materialising `Lemieux.Tools.default/0` when it is
  unset.

  An extension appending or wrapping a tool wants the list the session would
  otherwise use, and for a new session that is the default set. For a
  resumed one it is the recorded set, which only the host can supply — see
  the module documentation.
  """
  @spec update_tools(harness :: t(), fun :: ([Tool.t()] -> [Tool.t()])) :: t()
  def update_tools(%__MODULE__{} = harness, fun) when is_function(fun, 1),
    do: %{harness | tools: fun.(harness.tools || Tools.default())}

  @doc """
  Transforms the system prompt, materialising `Lemieux.Prompt.default/0`
  when it is unset.

  The function receives `nil` when a host disabled the prompt outright, and
  decides what composing over nothing means for it.
  """
  @spec update_system(harness :: t(), fun :: (String.t() | nil -> String.t() | nil)) :: t()
  def update_system(%__MODULE__{system: :default} = harness, fun) when is_function(fun, 1),
    do: %{harness | system: fun.(Prompt.default())}

  def update_system(%__MODULE__{} = harness, fun) when is_function(fun, 1),
    do: %{harness | system: fun.(harness.system)}

  @doc "Appends host tools. Appending none leaves the field as it was."
  @spec append_host_tools(harness :: t(), tools :: [Tool.t()]) :: t()
  def append_host_tools(%__MODULE__{} = harness, []), do: harness

  def append_host_tools(%__MODULE__{} = harness, tools) when is_list(tools),
    do: %{harness | host_tools: (harness.host_tools || []) ++ tools}

  @doc """
  Appends hooks after the ones already there.

  After, not before: the host's hooks were passed first and run first, and a
  dependency's policy running ahead of the host's would let it answer a call
  the host meant to deny. Appending none leaves the field as it was.
  """
  @spec append_hooks(harness :: t(), hooks :: Lemieux.Hooks.t()) :: t()
  def append_hooks(%__MODULE__{} = harness, []), do: harness

  def append_hooks(%__MODULE__{} = harness, hooks) when is_list(hooks),
    do: %{harness | hooks: (harness.hooks || []) ++ hooks}

  @doc """
  Appends MCP server configurations, one per name. Appending none leaves the
  field as it was, which on a resume is the difference between keeping the
  recorded servers and replacing them with an empty list.

  A server whose name is taken already, by one appended before it, is left
  out, and a notice says which two collided. The session keys its servers
  by name, so it can run one of each; given two, it used to keep whichever
  came last, silently, and extensions append in order — so a plugin's
  server replaced the person's own server of the same name without a word.
  The first wins because the first extensions are the ones closest to the
  person: their own servers and the files they named come before anything a
  plugin or a later extension adds.
  """
  @spec append_mcp_servers(harness :: t(), servers :: [map()]) :: t()
  def append_mcp_servers(%__MODULE__{} = harness, []), do: harness

  def append_mcp_servers(%__MODULE__{} = harness, servers) when is_list(servers) do
    {kept, notices} =
      Enum.reduce(servers, {harness.mcp_servers || [], []}, fn server, {kept, notices} ->
        name = server_name(server)

        case Enum.find(kept, &(server_name(&1) == name)) do
          nil -> {kept ++ [server], notices}
          used -> {kept, notices ++ [collision(name, used, server)]}
        end
      end)

    %{harness | mcp_servers: kept, notices: harness.notices ++ notices}
  end

  # The name the session will give it: `Lemieux.MCP.config/1` is how a
  # session reads a configuration, string keys or atom keys alike.
  defp server_name(server), do: Lemieux.MCP.config(server)["name"]

  defp collision(name, used, left_out),
    do:
      "Two MCP servers are named #{name}; the one from #{origin(used)} is used, and the " <>
        "one from #{origin(left_out)} is left out."

  # Where `Lemieux.MCP.Config` and the extensions that read one say a server
  # came from; see the `"source"` values in `Lemieux.MCP`.
  defp origin(server) do
    case Lemieux.MCP.config(server)["source"] do
      "personal" -> "your own settings"
      "explicit" -> "a file named for this run"
      source when source in ["project", "trusted"] -> "the repository's .mcp.json"
      "plugin" -> "a plugin"
      _other -> "the host"
    end
  end

  @doc "Transforms the harness context, materialising an empty map when it is unset."
  @spec update_harness_context(harness :: t(), fun :: (map() -> map())) :: t()
  def update_harness_context(%__MODULE__{} = harness, fun) when is_function(fun, 1),
    do: %{harness | harness_context: fun.(harness.harness_context || %{})}
end
