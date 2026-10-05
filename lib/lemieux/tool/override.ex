defmodule Lemieux.Tool.Override do
  @moduledoc """
  A tool with what the model reads about it changed, or what runs when it is
  called wrapped — and nothing else.

  Wraps any `Lemieux.Tool` and replaces the description — optionally the name
  and argument schema too — that the model reads, while `run` is delegated to
  the wrapped tool. Given `before` or `after`, it also puts a function in
  front of that delegation or behind it. Everything about the tool that is
  not overridden still comes from the wrapped one: whether it may share a
  wave, whether it only reads, its descriptor metadata, and — for a text-only
  override — its implementation digest.

  ## Why text is a first-class mutation

  Tool descriptions and schemas are a bounded tuning surface independent of
  executor code. A discovery candidate can change what the model reads about
  a built-in while preserving its implementation identity. Whether a text edit
  improves quality or transfers to another model requires paired evaluation
  and independent confirmation.

  The obvious alternative is a host module per variant. It fails twice: a
  module is compile-time, so a proposer cannot produce one, and its
  implementation digest differs from the built-in's even though the code that
  runs is identical, so evidence would report a different tool where only the
  text changed.

  ## Wrapping execution

  `before` and `after` let an override change what runs, not only what the
  model reads. `before` receives the arguments and the context and returns
  `{:ok, args}` for the wrapped tool, or `{:error, reason}`, which becomes the
  call's result — the wrapped tool does not run and `after` is not consulted,
  because there is nothing to consult it about. `after` receives whatever the
  wrapped tool returned, the effective arguments and the context, and what it
  returns is the result. Anything else a wrapper returns is a bug in the
  wrapper and raises as one; the session turns that into an error result that
  names it.

  `after` gets the return **verbatim, `{:stream, enumerable}` included**, and
  the stream is unforced on purpose. Collecting it so a wrapper could see the
  text would end live output for every decorated `bash`, and the wrapper
  would be the only thing that noticed. A wrapper that wants to touch streamed
  output wraps the enumerable — `Stream.map/2`, `Stream.each/2`, a
  `Stream.resource/3` around it — and leaves the pull to the collector, which
  is also what keeps abandoned-stream cleanup working (see
  `Lemieux.Tool.collect_result/3`).

  This is the smallest unit of "extend" the harness has. An audit log around
  `bash`, a path allowlist in front of `write`, a redaction pass over `read`:
  each is a function, applied to a catalog through `Lemieux.Tool.decorate/2`
  by whatever host, profile or extension wants it, with no module to write and
  nothing to register. A wrapper that adds an effect the wrapped tool did not
  have — an `after` that writes a file around `read` — should say so by
  wrapping the result in a `Lemieux.Tool.Descriptor` with its effects
  declared; the override itself answers `read_only?/1` and `parallel_safe?/1`
  for the wrapped tool, because it cannot know.

  ### A wrapper is part of the implementation

  A text override keeps the wrapped tool's implementation digest, because the
  code that runs is the wrapped tool's. A wrapping override does not: what
  runs is now the wrapper too, and evidence that reported the plain `bash`
  for a `bash` whose arguments a wrapper rewrote would be wrong about the one
  thing an implementation digest exists to say. So the wrapper's digest is
  folded into `identity.implementation_digest`, and `origin.overrides.fields`
  lists `"run"`, which is how a reader tells a decorated tool from a
  described one.

  The wrapper's digest is `:digest` when given, and that is the option for a
  wrapper that means to be recognised across builds. Otherwise it is derived
  from each function's defining module (its `module_info(:md5)`) and name,
  which is exactly as stable as the module: two overrides built from the same
  capture in one build agree, but an anonymous closure is named by its
  position in the function that created it, so adding a `fn` above it — or
  recompiling the module for any reason — changes the digest without changing
  the wrapper. That is the right answer to "did the same code run" and the
  wrong one to "is this the audit-v1 policy", which is what `:digest` is for.

  ## What the descriptor says

  The override keeps the wrapped tool's identity (namespace, canonical name,
  implementation digest), origin, effects, policy, runtime and lifecycle, so
  evidence attributes the work to the code that did it. It adds
  `origin.overrides` — `%{"tool" => wrapped name, "fields" => [...]}` — and the
  same map at the top level of `metadata/1`, so a reader of a harness snapshot
  can tell an overridden `read` from the plain one. A renamed override lists
  the wrapped name among its aliases. Because the description is part of the
  descriptor interface, every distinct override has a distinct descriptor
  digest: two candidates that differ only in tool text are distinguishable in
  evidence, which is the whole point.

  ## Not recorded, not restored

  `Lemieux.Session` records only module tools in the `:session` entry and
  restores them by name on resume; a configured struct is host-supplied and is
  left out of that record, exactly as `Lemieux.Extensions.Workspace.SkillTool` and
  `Lemieux.Subagent.Delegate` are. An override follows the same contract: the
  host that constructed it (a profile, a discovery candidate) passes it again.
  A wrapping override could not be recorded anyway: a function does not
  survive JSON.
  Recording the wrapped module in its place was considered and rejected — a
  resumed session would then be shown the plain `read` while its transcript
  says the model was shown something else, which is the silent configuration
  drift the recorded set exists to prevent.
  """

  @behaviour Lemieux.Tool.Configured

  alias Lemieux.Tool

  @typedoc "Runs before the wrapped tool; may rewrite the arguments or refuse the call."
  @type before :: (Tool.args(), Tool.context() -> {:ok, Tool.args()} | {:error, term()})

  @typedoc "Runs after the wrapped tool with its return verbatim; decides the result."
  @type after_fun :: (Tool.run_return(), Tool.args(), Tool.context() -> Tool.run_return())

  @type t :: %__MODULE__{
          tool: Tool.t(),
          description: String.t() | nil,
          name: String.t() | nil,
          schema: map() | nil,
          before: before() | nil,
          after: after_fun() | nil,
          digest: String.t() | nil
        }

  @enforce_keys [:tool]
  defstruct [:tool, :description, :name, :schema, :before, :after, :digest]

  # Alphabetical, so `fields` in the descriptor is stable across constructions.
  @fields [:description, :name, :schema]
  @wrappers [:after, :before]
  @options @fields ++ @wrappers ++ [:digest]

  @doc """
  Wraps `tool`, overriding the fields given in `opts`.

  Options are `:description`, `:name` and `:schema` for what the model reads,
  `:before` and `:after` for what runs, and `:digest` to name a wrapper (see
  the moduledoc). At least one non-nil override is required: an override that
  changes nothing is a misconfiguration, and letting it pass would hide a
  misspelled option key. Unknown keys are rejected for the same reason, and
  so is a `:digest` with no wrapper to name. The wrapped tool is validated the
  way a session catalog is, so a bad inner tool fails here rather than at the
  first paid request.
  """
  @spec new(tool :: Tool.t(), opts :: keyword()) :: {:ok, t()} | {:error, term()}
  def new(tool, opts \\ []) when is_list(opts) do
    with :ok <- known_options(opts),
         :ok <- validate_digest(opts[:digest], opts[:before], opts[:after]),
         :ok <- something_overridden(opts),
         :ok <- validate_inner(tool),
         :ok <- validate_description(opts[:description]),
         :ok <- validate_name(opts[:name]),
         :ok <- validate_schema(opts[:schema]),
         :ok <- validate_wrapper(:before, opts[:before], 2),
         :ok <- validate_wrapper(:after, opts[:after], 3) do
      {:ok, struct!(__MODULE__, Keyword.put(opts, :tool, tool))}
    end
  end

  @doc "Like `new/2`, raising `ArgumentError` on an invalid override."
  @spec new!(tool :: Tool.t(), opts :: keyword()) :: t()
  def new!(tool, opts \\ []) do
    case new(tool, opts) do
      {:ok, override} -> override
      {:error, reason} -> raise ArgumentError, "invalid tool override: #{inspect(reason)}"
    end
  end

  @impl Lemieux.Tool.Configured
  @spec name(override :: t()) :: String.t()
  def name(%__MODULE__{name: nil, tool: tool}), do: Tool.name(tool)
  def name(%__MODULE__{name: name}), do: name

  @impl Lemieux.Tool.Configured
  @spec description(override :: t()) :: String.t()
  def description(%__MODULE__{description: nil, tool: tool}), do: Tool.description(tool)
  def description(%__MODULE__{description: description}), do: description

  @impl Lemieux.Tool.Configured
  @spec schema(override :: t()) :: map()
  def schema(%__MODULE__{schema: nil, tool: tool}), do: Tool.schema(tool)
  def schema(%__MODULE__{schema: schema}), do: schema

  @impl Lemieux.Tool.Configured
  @spec run(override :: t(), args :: Tool.args(), context :: Tool.context()) ::
          Tool.run_return()
  def run(%__MODULE__{tool: tool, before: nil, after: nil}, args, context),
    do: Tool.invoke(tool, args, context)

  def run(%__MODULE__{tool: tool} = override, args, context) do
    case run_before(override, args, context) do
      {:ok, args} -> run_after(override, Tool.invoke(tool, args, context), args, context)
      {:error, _reason} = error -> error
    end
  end

  defp run_before(%__MODULE__{before: nil}, args, _context), do: {:ok, args}

  defp run_before(%__MODULE__{before: before} = override, args, context) do
    case before.(args, context) do
      {:ok, rewritten} when is_map(rewritten) ->
        {:ok, rewritten}

      {:error, _reason} = error ->
        error

      other ->
        raise ArgumentError,
              "the before wrapper on #{name(override)} returned #{inspect(other)}; " <>
                "expected {:ok, args} or {:error, reason}"
    end
  end

  defp run_after(%__MODULE__{after: nil}, inner, _args, _context), do: inner

  defp run_after(%__MODULE__{after: after_fun}, inner, args, context),
    do: after_fun.(inner, args, context)

  @impl Lemieux.Tool.Configured
  @spec parallel_safe?(override :: t()) :: boolean()
  def parallel_safe?(%__MODULE__{tool: tool}), do: Tool.parallel_safe?(tool)

  @impl Lemieux.Tool.Configured
  @spec read_only?(override :: t()) :: boolean()
  def read_only?(%__MODULE__{tool: tool}), do: Tool.read_only?(tool)

  @impl Lemieux.Tool.Configured
  @spec metadata(override :: t()) :: map()
  def metadata(%__MODULE__{tool: tool} = override) do
    wrapped = Tool.name(tool)
    overrides = %{"tool" => wrapped, "fields" => fields(override)}

    # The wrapped tool's resolved descriptor, minus the two interface fields
    # this struct answers for itself. Dropping them matters: `Descriptor.new/2`
    # merges declared metadata over its defaults, so leaving the wrapped
    # description in would put it back over the override.
    tool
    |> Tool.descriptor()
    |> Tool.metadata()
    |> without_empty_lists()
    |> Map.update!("interface", &Map.drop(&1, ["description", "input_schema"]))
    |> Map.update!("identity", &alias_wrapped(&1, wrapped, name(override)))
    |> Map.update!("identity", &implementation(&1, override))
    |> Map.update!("origin", &Map.put(&1, "overrides", overrides))
    |> Map.put("overrides", overrides)
  end

  defp implementation(identity, %__MODULE__{before: nil, after: nil}), do: identity

  defp implementation(identity, %__MODULE__{} = override) do
    Map.update!(identity, "implementation_digest", fn wrapped ->
      sha256(wrapped <> ":" <> wrapper_digest(override))
    end)
  end

  defp wrapper_digest(%__MODULE__{digest: digest}) when is_binary(digest), do: digest

  defp wrapper_digest(%__MODULE__{before: before, after: after_fun}),
    do: Enum.map_join([before, after_fun], "|", &function_digest/1)

  defp function_digest(nil), do: "-"

  defp function_digest(fun) when is_function(fun) do
    info = Function.info(fun)
    module = info[:module]

    md5 =
      if Code.ensure_loaded?(module),
        do: Base.encode16(module.module_info(:md5), case: :lower),
        else: "unloaded"

    "#{inspect(module)}.#{info[:name]}/#{info[:arity]}@#{md5}"
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp alias_wrapped(identity, wrapped, wrapped), do: identity

  defp alias_wrapped(identity, wrapped, _renamed),
    do: Map.update(identity, "aliases", [wrapped], &Enum.uniq(&1 ++ [wrapped]))

  # `Descriptor.new/2` normalises declared metadata with `Keyword.keyword?/1`, which
  # is true of `[]`, so an inherited empty list would come back as an empty map and
  # the override's descriptor would differ from the wrapped tool's in fields nobody
  # overrode. The descriptor defaults already hold `[]` for every such field.
  defp without_empty_lists(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> value == [] end)
    |> Map.new(fn {key, value} -> {key, without_empty_lists(value)} end)
  end

  defp without_empty_lists(value), do: value

  # "run" sorts among the text fields rather than trailing them, so the list
  # stays alphabetical whichever combination was set.
  defp fields(%__MODULE__{} = override) do
    text =
      for field <- @fields, not is_nil(Map.fetch!(override, field)), do: Atom.to_string(field)

    if wrapping?(override), do: Enum.sort(["run" | text]), else: text
  end

  defp wrapping?(%__MODULE__{before: nil, after: nil}), do: false
  defp wrapping?(%__MODULE__{}), do: true

  defp known_options(opts) do
    case Keyword.keys(opts) -- @options do
      [] -> :ok
      [key | _rest] -> {:error, {:unknown_option, key}}
    end
  end

  defp something_overridden(opts) do
    overridden? =
      opts
      |> Keyword.take(@fields ++ @wrappers)
      |> Enum.any?(fn {_field, value} -> not is_nil(value) end)

    if overridden?, do: :ok, else: {:error, :nothing_overridden}
  end

  defp validate_wrapper(_field, nil, _arity), do: :ok
  defp validate_wrapper(_field, fun, arity) when is_function(fun, arity), do: :ok
  defp validate_wrapper(:before, _fun, _arity), do: {:error, :invalid_before}
  defp validate_wrapper(:after, _fun, _arity), do: {:error, :invalid_after}

  defp validate_digest(nil, _before, _after), do: :ok
  defp validate_digest(_digest, nil, nil), do: {:error, :digest_without_wrapper}

  defp validate_digest(digest, _before, _after) when is_binary(digest),
    do: if(String.trim(digest) == "", do: {:error, :invalid_digest}, else: :ok)

  defp validate_digest(_digest, _before, _after), do: {:error, :invalid_digest}

  defp validate_inner(tool) do
    case Tool.validate_all([tool]) do
      :ok -> :ok
      {:error, {:invalid_tool, 0, reason}} -> {:error, {:invalid_tool, reason}}
    end
  end

  defp validate_description(nil), do: :ok

  defp validate_description(description) when is_binary(description),
    do: if(String.trim(description) == "", do: {:error, :empty_description}, else: :ok)

  defp validate_description(_other), do: {:error, :invalid_description}

  defp validate_name(nil), do: :ok

  defp validate_name(name) when is_binary(name),
    do: if(String.trim(name) == "", do: {:error, :empty_name}, else: :ok)

  defp validate_name(_other), do: {:error, :invalid_name}

  defp validate_schema(nil), do: :ok

  defp validate_schema(%{"type" => "object"} = schema),
    do: if(json_safe?(schema), do: :ok, else: {:error, :invalid_schema})

  defp validate_schema(_other), do: {:error, :invalid_schema}

  defp json_safe?(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: true

  defp json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)

  defp json_safe?(value) when is_map(value),
    do: Enum.all?(value, fn {key, nested} -> is_binary(key) and json_safe?(nested) end)

  defp json_safe?(_value), do: false
end
