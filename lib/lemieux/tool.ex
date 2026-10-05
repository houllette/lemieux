defmodule Lemieux.Tool do
  @moduledoc """
  Something the model can do.

  A tool is a name the model calls it by, a description it decides from, a
  JSON Schema for its arguments, and `run`. lemieux ships four —
  `Lemieux.Tools.Read`, `.Write`, `.Edit` and `.Bash` — and a host adds its
  own by implementing this behaviour and passing the module in a session's
  `:tools`.

  ## A tool of your own

      defmodule MyApp.Tools.Weekday do
        @behaviour Lemieux.Tool

        @impl true
        def name, do: "weekday"

        @impl true
        def description, do: "Names the day of the week a date falls on."

        @impl true
        def schema do
          %{
            "type" => "object",
            "properties" => %{
              "date" => %{"type" => "string", "description" => "The date, as YYYY-MM-DD"}
            },
            "required" => ["date"]
          }
        end

        @impl true
        def run(%{"date" => date}, _context) do
          case Date.from_iso8601(date) do
            {:ok, date} -> {:ok, Calendar.strftime(date, "%A")}
            {:error, _reason} -> {:error, "\#{date} is not a date written as YYYY-MM-DD"}
          end
        end

        def run(_args, _context), do: {:error, "a date is required"}

        @impl true
        def read_only?, do: true

        @impl true
        def parallel_safe?, do: true
      end

  Pass it beside the defaults, as `tools: Lemieux.Tools.default() ++
  [MyApp.Tools.Weekday]`. Both of `run/2`'s answers reach the model, which is
  how it learns that `"next Tuesday"` was not a date. The two optional
  callbacks say the tool only looks at things and can share a wave of calls;
  a tool that leaves them out is treated as one that writes.

  ## Two planes

  A tool is either a **module** implementing this behaviour or a **configured
  struct** whose module implements `Lemieux.Tool.Configured`, and the
  difference is whether it carries runtime state. `Lemieux.Tools.Read` needs
  nothing but its code, so it is a bare module. A `bash` whose commands run
  through a host's remote runner, a `web_search` bound to a backend and a
  budget, a `skill` loader holding the files a host discovered — these exist
  only once a host has supplied something at runtime, and a module has
  nowhere to keep it. They are structs, and their operations take the struct
  as the first argument.

  Everything below this module treats the two alike — dispatch, the request
  sent to the model, hooks, approval, the transcript — because every reader
  goes through `name/1`, `description/1`, `schema/1` and `invoke/3` here
  rather than calling a module directly. The one place they part on purpose
  is resume: a session records module tools by name and restores them, while
  a configured struct is host state the host passes again, because a runner
  or a credential cannot be rebuilt from JSON (see `Lemieux.Session`).

  ## Four tools, not forty

  The library's default set is deliberately close to the smallest one a
  frontier model can work a repository with. Every additional tool is a
  permanent tax on the context window and one more way for the model to pick
  the wrong instrument, and `bash` already covers searching, listing, running
  tests and everything else a shell can do. So `Lemieux.Tools.default/0`
  stays these four, and a tool beyond them ships as an extension a host
  chooses to apply rather than as a fifth default.

  Search is the one `lmx` applies (`Lemieux.Extensions.Search`, adding
  `grep` and `glob`), and it earns its place on things `bash` cannot offer
  rather than on convenience: it is certified read-only, so a read-only
  investigator or a host that allows no commands can still search; its output
  is bounded and says where it stopped, where a shell pipeline's is whatever
  the command prints; and it honours `.gitignore` without the model having to
  remember to. The same test applies to any other candidate: a property the
  four cannot provide, not a job they could already do.

  ## Failure is a result, not an exception

  `run/2` returns `{:ok, output}` or `{:error, reason}`, and **both go back to
  the model**. A tool that cannot find its file, a command that exits
  non-zero, a string that does not match — these are the ordinary content of
  an agent's work, and the model's next move depends on being told which one
  happened. A tool that crashes gets the same treatment (see
  `Lemieux.Session`): the exception becomes an error result the model can
  read, rather than a dead session.

  The one thing a tool must never do is fail silently or claim success it did
  not have. Everything downstream — the transcript, the hook that denied it,
  the person reading the log — is only as honest as this return value.

  ## Output is capped

  Tools return text into a context window, so every tool that can produce
  unbounded output truncates it and **says so in the output itself**. Silent
  truncation is the failure mode that matters: a model that reads the first
  half of a file and is not told it was the first half will confidently
  conclude the rest does not exist.
  """

  alias Lemieux.MCP
  alias Lemieux.MCP.RemoteTool
  alias Lemieux.Tool.Configured
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tool.Result

  # Substituted by `stated/2` — see the comment on that function for why the
  # empty string is not a tool result.
  @no_output "(the tool returned no output)"
  @no_reason "(the tool failed without saying why)"

  @typedoc """
  What a tool is told about the session it is running in.

  `session` is the process, and is here so a tool can park itself and wait for
  an answer — see `Lemieux.Session.park/4` and `Lemieux.Tools.AskUser`. Almost
  no tool needs it; the ones that do cannot work without it.

  `supervisor` is the mounted `Lemieux.Supervisor`'s name, for the same reason
  and with the same caveat: a tool that has to start something supervised —
  `Lemieux.Tools.Eval` and its evaluation node — has no other way to find
  the runtime it belongs to, and a library that reached for a global one would
  stop two runtimes in a VM being independent.

  `hooks` is supplied by `Lemieux.Tools.run/5` from the effective invocation
  policy. A composed tool passes it to nested `Tools.run` calls so final host
  overrides and parked approvals apply to each inner operation. Do not retain
  executable hooks in transcript evidence or capture them during assembly.

  `input_modalities` is what the session's model can be shown besides text,
  as the model catalog names it (`:image`, `:pdf`), or `:unknown`. A tool that
  can return an attachment (`Lemieux.Tool.Attachment`) asks it first, and
  answers in words when the model cannot look: an image a model cannot read
  is a provider refusal on every request that carries it. Absent means
  `:unknown`.
  """
  @type context :: %{
          optional(:tool_descriptor) => map(),
          optional(:tool_output_bytes) => pos_integer(),
          optional(:deadline_ms) => pos_integer(),
          optional(:hooks) => Lemieux.Hooks.t(),
          optional(:input_modalities) => [atom()] | :unknown,
          cwd: Path.t(),
          environment: Lemieux.Environment.t(),
          session_id: String.t(),
          call_id: String.t(),
          session: pid(),
          supervisor: atom()
        }

  @typedoc "A tool's arguments, as the model produced them: JSON, string keys."
  @type args :: map()

  @typedoc "One streamed chunk, terminal structured success, or terminal execution failure."
  @type stream_item :: iodata() | {:ok, Result.t()} | {:error, term()}

  @typedoc "What `run` returns: a result, a failure, or a stream of `t:stream_item/0`."
  @type run_return :: {:ok, iodata() | Result.t()} | {:error, term()} | {:stream, Enumerable.t()}

  @typedoc """
  A tool: a module implementing this behaviour, or a remote one a server
  described at runtime.
  """
  @type t :: module() | struct() | RemoteTool.t() | Descriptor.t()

  @doc "The name the model calls this tool by."
  @callback name() :: String.t()

  @doc "What the tool does, as the model reads it."
  @callback description() :: String.t()

  @doc "A JSON Schema object describing the arguments."
  @callback schema() :: map()

  @doc """
  Does the thing. Every return reaches the model.

  A streamed tool yields output chunks as they arrive. If execution fails
  after streaming has begun, its final item is `{:error, reason}`; collection
  keeps the output already received and marks the complete result as an error.
  It may instead end with `{:ok, Result.t()}` to retain structured evidence.
  That result's text is the final chunk, appended directly to earlier output;
  do not repeat the accumulated output in it. Either terminal item closes the
  stream, including its resource cleanup.
  """
  @callback run(args :: args(), context :: context()) ::
              {:ok, iodata() | Result.t()} | {:error, term()} | {:stream, Enumerable.t()}

  @doc """
  May this tool run at the same time as the other calls in its wave?

  Optional, and **the default is no**, which is the only safe way round. A
  model routinely asks for several tools in one assistant turn, and lemieux
  used to start all of them at once: two `edit` calls against one file then
  both read it, both wrote it, and the first edit was gone with nothing in the
  transcript to say so. Silence is what makes that the wrong default — a lost
  edit looks exactly like a model that changed its mind.

  So a tool is assumed to write unless it says otherwise, and only a tool that
  touches nothing another call in the same wave could be touching answers
  `true`. `Lemieux.Tools.Read` does; `bash` cannot, because a shell command is
  anything at all.

  A host's own tool gets the same benefit of the doubt: implement nothing and
  it is scheduled alone.
  """
  @callback parallel_safe?() :: boolean()

  @doc """
  Does this tool only look at things?

  Optional, defaulting to **no**, and a different question from
  `c:parallel_safe?/0` however much the two overlap. That one asks whether a
  tool may share its wave; this one asks whether it may be trusted with work
  somebody else asked for.

  The distinction earns its keep at exactly one boundary, and it is the one
  that matters: `Lemieux.A2A` lets another agent ask this one a question, and
  a question is not permission to write. A remote task runs with the read-only
  tools and nothing else, so an agent that has been talked into asking for
  something destructive cannot get it done here by asking politely.

  `Lemieux.Tools.Read` is read-only. `bash` is not, and cannot be: a shell
  command is anything at all, and a scan of the string is not an argument —
  `Lemieux.Tools.Eval` is not either, for the same reason at a different
  scale. `Lemieux.Tools.AskUser` is not, despite touching no file: what it
  spends is a person's attention, and spending somebody's attention on a
  stranger's question is its own kind of write.
  """
  @callback read_only?() :: boolean()

  @doc "Descriptor-v1 metadata a host or bundled tool can declare."
  @callback metadata() :: map()

  @optional_callbacks parallel_safe?: 0, read_only?: 0, metadata: 0

  @doc """
  Validates a catalog before it is shown to a provider.

  Provider APIs identify tools by name, so a duplicate is not harmless: the
  model can ask for one definition while dispatch runs the other. Metadata is
  checked here, once, so an invalid callback or schema fails session startup
  instead of crashing after a paid request has already been made.
  """
  @spec validate_all(tools :: [t()]) :: :ok | {:error, term()}
  def validate_all(tools) when is_list(tools) do
    case validate_tools(tools) do
      :ok -> tools |> Enum.map(&name/1) |> validate_unique()
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Finds the tool named `name` among `tools`.
  """
  @spec fetch(tools :: [t()], name :: String.t()) :: {:ok, t()} | :error
  def fetch(tools, name) when is_list(tools) and is_binary(name) do
    case Enum.find(tools, &(name(&1) == name)) do
      nil -> :error
      tool -> {:ok, tool}
    end
  end

  @typedoc "A function from a tool to the tool that should stand in its place."
  @type wrapper :: (t() -> t())

  @doc """
  Wraps the tools in `tools` that `wrappers` names, in place.

  `wrappers` maps a tool name to a function from that tool to its
  replacement: a `Lemieux.Tool.Override` that changes what the model reads or
  what runs, a `Lemieux.Tool.Descriptor` that declares more about it, or any
  other tool. Everything that layers behaviour onto a catalog composes
  through here — a learning overlay redescribing `write`, a profile
  redescribing `read`, a host auditing `bash` — rather than each writing its
  own loop over the list, which two callers had already done.

  A name that matches no tool raises. A wrapper for a tool the catalog does
  not carry is a misspelled name or a catalog the caller misunderstands, and
  applying nothing is how an audit wrapper turns out never to have been
  installed. A caller that genuinely means "if present" filters its map
  first, as `Lemieux.Learning.Overlay.apply_tools/2` does, because an overlay
  describes tools a narrowed catalog may lack. A name given twice, or one
  that two tools in `tools` share, raises too: either would apply a wrapper
  twice, and `validate_all/1` would reject the second catalog anyway.
  """
  @spec decorate(
          tools :: [t()],
          wrappers :: %{optional(String.t()) => wrapper()} | [{String.t(), wrapper()}]
        ) :: [t()]
  def decorate(tools, wrappers) when is_list(tools) and (is_map(wrappers) or is_list(wrappers)) do
    wrappers = Enum.to_list(wrappers)
    names = Enum.map(tools, &name/1)
    Enum.each(wrappers, &check_wrapper(&1, names, wrappers))
    lookup = Map.new(wrappers)

    Enum.map(tools, fn tool ->
      case Map.fetch(lookup, name(tool)) do
        {:ok, wrapper} -> wrap(tool, wrapper)
        :error -> tool
      end
    end)
  end

  defp check_wrapper({name, wrapper}, names, wrappers) when is_binary(name) do
    cond do
      not is_function(wrapper, 1) ->
        raise ArgumentError,
              "the wrapper for #{inspect(name)} is not a function of one argument: " <>
                inspect(wrapper)

      Enum.count(wrappers, &(elem(&1, 0) == name)) > 1 ->
        raise ArgumentError, "the tool #{inspect(name)} is named twice; a wrapper applies once"

      true ->
        check_present(name, names)
    end
  end

  defp check_wrapper(other, _names, _wrappers) do
    raise ArgumentError, "tool wrappers are {name, function} pairs; got #{inspect(other)}"
  end

  defp check_present(name, names) do
    case Enum.count(names, &(&1 == name)) do
      1 ->
        :ok

      0 ->
        catalog = if names == [], do: "no tools", else: Enum.join(names, ", ")

        raise ArgumentError,
              "no tool named #{inspect(name)} to decorate; the catalog has #{catalog}"

      _more ->
        raise ArgumentError,
              "two tools named #{inspect(name)}; a wrapper must apply to exactly one"
    end
  end

  defp wrap(tool, wrapper) do
    case wrapper.(tool) do
      replacement when is_struct(replacement) ->
        replacement

      replacement
      when is_atom(replacement) and not is_nil(replacement) and
             not is_boolean(replacement) ->
        replacement

      other ->
        raise ArgumentError,
              "the wrapper for #{inspect(name(tool))} returned #{inspect(other)}, not a tool"
    end
  end

  defp validate_tools(tools) do
    tools
    |> Enum.with_index()
    |> Enum.reduce_while(:ok, fn {tool, index}, :ok ->
      case validate_tool(tool) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:invalid_tool, index, reason}}}
      end
    end)
  end

  defp validate_tool(%Descriptor{} = descriptor) do
    with :ok <- validate_tool(descriptor.executor),
         :ok <- Descriptor.validate(descriptor) do
      validate_metadata(descriptor)
    end
  end

  defp validate_tool(%RemoteTool{} = tool) do
    with :ok <- validate_metadata(tool), do: validate_descriptor(tool)
  end

  defp validate_tool(%module{} = tool) do
    with :ok <- configured_callbacks(module),
         :ok <- validate_metadata(tool) do
      validate_descriptor(tool)
    end
  end

  defp validate_tool(module) when is_atom(module) do
    with :ok <- required_callbacks(module, name: 0, description: 0, schema: 0, run: 2),
         :ok <- validate_metadata(module) do
      validate_descriptor(module)
    end
  end

  defp validate_tool(_tool), do: {:error, :unsupported_shape}

  # Duck-typed on purpose: a struct tool that never declared
  # `Lemieux.Tool.Configured` still validates, because what dispatch needs is
  # the four functions, not the attribute. The error names the behaviour so a
  # struct that is short of one finds the contract without searching for it.
  defp configured_callbacks(module) do
    case Configured.missing_callbacks(module) do
      [] ->
        :ok

      missing ->
        {:error, {:missing_callbacks, module, %{behaviour: Configured, missing: missing}}}
    end
  end

  defp required_callbacks(module, callbacks) do
    if Code.ensure_loaded?(module) and
         Enum.all?(callbacks, fn {name, arity} -> function_exported?(module, name, arity) end),
       do: :ok,
       else: {:error, {:missing_callbacks, module}}
  end

  defp validate_metadata(tool) do
    with tool_name when is_binary(tool_name) and byte_size(tool_name) > 0 <- name(tool),
         description when is_binary(description) and byte_size(description) > 0 <-
           description(tool),
         %{"type" => "object"} = schema <- schema(tool),
         true <- json_safe?(schema) do
      :ok
    else
      _invalid -> {:error, :invalid_metadata}
    end
  end

  defp validate_descriptor(tool) do
    tool |> descriptor() |> Descriptor.validate()
  rescue
    _error -> {:error, :invalid_descriptor}
  catch
    _kind, _reason -> {:error, :invalid_descriptor}
  end

  defp validate_unique(names) do
    case names -- Enum.uniq(names) do
      [] -> :ok
      [duplicate | _rest] -> {:error, {:duplicate_tool_name, duplicate}}
    end
  end

  defp json_safe?(value) when is_binary(value) or is_number(value) or is_boolean(value), do: true
  defp json_safe?(nil), do: true
  defp json_safe?(value) when is_list(value), do: Enum.all?(value, &json_safe?/1)

  defp json_safe?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json_safe?(nested) end)
  end

  defp json_safe?(_value), do: false

  @doc """
  The name a tool is offered to the model under.

  A tool is either a module implementing this behaviour or a
  `Lemieux.MCP.RemoteTool`, which describes something a server offers and
  cannot be a module because it did not exist at compile time. Everything that
  reads a tool's metadata goes through these four functions so that the two
  shapes stay interchangeable everywhere else — dispatch, the request sent to
  the model, hooks, approval and the transcript all treat them alike.
  """
  @spec name(tool :: t()) :: String.t()
  def name(%Descriptor{} = descriptor), do: descriptor.identity["name"]
  def name(%RemoteTool{} = tool), do: RemoteTool.qualified_name(tool)
  def name(%module{} = tool), do: module.name(tool)
  def name(module) when is_atom(module), do: module.name()

  @doc """
  What the tool tells the model it does.
  """
  @spec description(tool :: t()) :: String.t()
  def description(%Descriptor{} = descriptor), do: descriptor.interface["description"]
  def description(%RemoteTool{} = tool), do: tool.description
  def description(%module{} = tool), do: module.description(tool)
  def description(module) when is_atom(module), do: module.description()

  @doc """
  The JSON Schema of the tool's arguments.
  """
  @spec schema(tool :: t()) :: map()
  def schema(%Descriptor{} = descriptor), do: descriptor.interface["input_schema"]
  def schema(%RemoteTool{} = tool), do: tool.schema
  def schema(%module{} = tool), do: module.schema(tool)
  def schema(module) when is_atom(module), do: module.schema()

  @doc """
  Whether this tool may share its wave with the other calls in it.

  See the `c:parallel_safe?/0` callback for why the answer defaults to `false`.
  A tool a server described at runtime always gets `false`: MCP has a
  `readOnlyHint` annotation, but it is a hint a server may omit, may get wrong,
  and costs nothing to claim — and the price of believing a wrong one is a
  silently lost write.

  ## One answer, from the descriptor

  A tool can say this twice — the callback, and `runtime.concurrency.class`
  in `c:metadata/0` — and the two used to be read by different callers: the
  scheduler went by the descriptor, everything else by the callback. A tool
  whose two answers disagreed was then parallel for one reader and exclusive
  for another. The declared metadata wins now, everywhere, which is also what
  its descriptor says; the callback is the shorthand used when the metadata is
  silent.
  """
  @spec parallel_safe?(tool :: t()) :: boolean()
  def parallel_safe?(%Descriptor{} = descriptor),
    do: Descriptor.concurrency(descriptor) == :parallel

  def parallel_safe?(%RemoteTool{}), do: false

  def parallel_safe?(tool) do
    case declared(tool, ["runtime", "concurrency", "class"]) do
      nil -> declared_parallel_safe?(tool)
      class -> class == "parallel"
    end
  end

  @doc """
  Whether this tool only reads.

  See the `c:read_only?/0` callback. A tool a server described at runtime
  gets `false` for the same reason it gets `false` from `parallel_safe?/1`:
  MCP's `readOnlyHint` is a hint, a server may omit it or get it wrong, and
  it costs nothing to claim.

  As with `parallel_safe?/1`, a declared `effects.class` in `c:metadata/0` is
  the answer (`"read"` or not) and the callback applies only when the
  metadata says nothing, so this and the tool's descriptor always agree.
  """
  @spec read_only?(tool :: t()) :: boolean()
  def read_only?(%Descriptor{} = descriptor), do: descriptor.effects["class"] == "read"
  def read_only?(%RemoteTool{}), do: false

  def read_only?(tool) do
    case declared(tool, ["effects", "class"]) do
      nil -> declared_read_only?(tool)
      class -> class == "read"
    end
  end

  @doc """
  What a tool declares about asking a person before it runs.

  `:never` for a tool that declares `policy.approval` `"never"` — reading a
  file is not something to ask about — `:always` for one that declares
  `"always"`, and `:policy` otherwise, meaning the host's policy decides. The
  library enforces none of it; a permission layer (a host's
  `before_tool_call`, `Lemieux.Extensions.Permissions`) reads it here.
  """
  @spec approval(tool :: t()) :: :never | :always | :policy
  def approval(tool), do: tool |> descriptor() |> Descriptor.approval()

  # The callbacks alone, for a tool whose metadata is silent — and for
  # `Lemieux.Tool.Descriptor`, which seeds its defaults from them.
  defp declared_parallel_safe?(%module{} = tool) do
    Code.ensure_loaded?(module) and function_exported?(module, :parallel_safe?, 1) and
      module.parallel_safe?(tool)
  end

  defp declared_parallel_safe?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :parallel_safe?, 0) and
      module.parallel_safe?()
  end

  defp declared_read_only?(%module{} = tool) do
    Code.ensure_loaded?(module) and function_exported?(module, :read_only?, 1) and
      module.read_only?(tool)
  end

  defp declared_read_only?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :read_only?, 0) and
      module.read_only?()
  end

  # A declared metadata value by path, whether the tool wrote its keys as atoms
  # or strings and its value as an atom or a string.
  defp declared(tool, path), do: tool |> metadata() |> dig(path)

  defp dig(value, []) when is_binary(value), do: value
  defp dig(value, []) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp dig(_value, []), do: nil

  defp dig(map, [key | rest]) when is_map(map) do
    case Enum.find(map, fn {candidate, _value} -> to_string(candidate) == key end) do
      {_candidate, value} -> dig(value, rest)
      nil -> nil
    end
  end

  defp dig(_value, _path), do: nil

  @doc """
  The subset of `tools` that only read.

  What `Lemieux.A2A` equips a task somebody else asked for.
  """
  @spec read_only(tools :: [t()]) :: [t()]
  def read_only(tools) when is_list(tools), do: Enum.filter(tools, &read_only?/1)

  @doc """
  Runs the tool.
  """
  @spec invoke(tool :: t(), args :: args(), context :: context()) ::
          {:ok, iodata() | Result.t()} | {:error, term()} | {:stream, Enumerable.t()}
  def invoke(%Descriptor{} = descriptor, args, context),
    do: invoke(descriptor.executor, args, context)

  def invoke(%RemoteTool{} = tool, args, context), do: MCP.call_tool(tool, args, context)

  def invoke(%module{} = tool, args, context), do: module.run(tool, args, context)

  def invoke(module, args, context) when is_atom(module), do: module.run(args, context)

  @doc """
  Collects a tool return, forwarding streamed chunks as they arrive.

  A stream is capped independently from its final context-sized result. The
  first cap prevents a runaway enumerable from retaining unbounded memory;
  the second keeps its collected output from consuming the next model request.
  Stopping enumeration runs a `Stream.resource/3` cleanup callback, which is
  how the local command environment kills the process behind an abandoned
  stream.

  A terminal `{:error, reason}` item changes the collected return to an error
  without discarding chunks that arrived before the executor failed.
  """
  @spec collect(
          result :: {:ok, iodata() | Result.t()} | {:error, term()} | {:stream, Enumerable.t()},
          emit :: (String.t() -> any())
        ) :: {:ok, String.t()} | {:error, term()}
  def collect(result, emit \\ fn _chunk -> :ok end)

  def collect(result, emit) do
    case collect_result(result, emit, 30_000) do
      {:ok, structured} -> {:ok, structured.model_text}
      {:error, structured} -> {:error, structured.model_text}
    end
  end

  @doc "Collects and bounds the complete structured result for the execution envelope."
  @spec collect_result(
          result :: {:ok, iodata() | Result.t()} | {:error, term()} | {:stream, Enumerable.t()},
          emit :: (String.t() -> any()),
          max_bytes :: pos_integer()
        ) :: {:ok, Result.t()} | {:error, Result.t()}
  def collect_result(result, emit, max_bytes)

  def collect_result({:ok, output}, _emit, max_bytes) do
    {:ok, output |> normalize_result() |> bound(max_bytes) |> stated(@no_output)}
  end

  def collect_result({:error, reason}, _emit, max_bytes) do
    {:error, reason |> normalize_result() |> bound(max_bytes) |> stated(@no_reason)}
  end

  def collect_result({:stream, enumerable}, emit, max_bytes) do
    {chunks, _size, capped?, terminal} =
      Enum.reduce_while(enumerable, {[], 0, false, nil}, fn
        {:ok, %Result{} = result}, {chunks, size, _capped?, nil} ->
          result = result |> normalize_result() |> bound(max_bytes)
          emit.(result.model_text)
          {:halt, {chunks, size, false, {:ok, result}}}

        {:error, reason}, {chunks, size, _capped?, nil} ->
          error = reason |> normalize_result() |> bound(max_bytes) |> stated(@no_reason)
          emit.(error.model_text)
          {:halt, {chunks, size, false, {:error, error}}}

        chunk, {chunks, size, _capped?, nil} ->
          chunk = chunk |> IO.iodata_to_binary() |> sanitize()
          emit.(chunk)
          size = size + byte_size(chunk)

          if size > 8_000_000,
            do: {:halt, {chunks, size, true, nil}},
            else: {:cont, {[chunk | chunks], size, false, nil}}
      end)

    output = chunks |> Enum.reverse() |> IO.iodata_to_binary()

    case terminal do
      {:ok, result} ->
        result = %{result | model_text: output <> result.model_text}
        {:ok, result |> bound(max_bytes) |> stated(@no_output)}

      {:error, result} ->
        {:error, result |> prepend_output(output) |> bound(max_bytes)}

      nil ->
        output =
          if capped?,
            do: output <> "\n\n[tool stream stopped after 8000000 bytes]",
            else: output

        {:ok, output |> Result.new() |> bound(max_bytes) |> stated(@no_output)}
    end
  end

  @doc "Returns descriptor v1 for a legacy or already-described tool."
  @spec descriptor(tool :: t()) :: Descriptor.t()
  def descriptor(%Descriptor{} = descriptor), do: descriptor
  def descriptor(tool), do: Descriptor.new(tool)

  @doc "Returns optional descriptor metadata declared by a tool implementation."
  @spec metadata(tool :: t()) :: map()
  def metadata(%Descriptor{} = descriptor) do
    descriptor
    |> Descriptor.to_map()
    |> Map.take(~w(identity origin interface effects policy runtime lifecycle))
  end

  def metadata(%RemoteTool{} = tool) do
    %{
      "interface" => %{
        "output_schema" => Map.get(tool, :output_schema),
        "content_types" => Map.get(tool, :content_types, ["text/plain"])
      },
      "effects" => %{"mcp_annotations" => Map.get(tool, :annotations, %{})},
      "origin" => %{"metadata" => Map.get(tool, :meta, %{})}
    }
  end

  def metadata(%module{} = tool) do
    if Code.ensure_loaded?(module) and function_exported?(module, :metadata, 1),
      do: module.metadata(tool),
      else: %{}
  end

  def metadata(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :metadata, 0),
      do: module.metadata(),
      else: %{}
  end

  # The model is owed a result for every call it makes, and the empty string is not
  # one: it is stored in the transcript, re-sent on every later request, and reaches
  # the provider as empty content. `Lemieux.Tools.Bash` and the MCP client each
  # already substituted a sentence here, but nothing said it for a tool an embedder
  # wrote, and `c:run/2` has always permitted `{:ok, ""}`. Saying it once, at the
  # seam every result crosses, is the only place the guarantee holds. Whitespace
  # counts as silence: a provider that refuses an empty text block refuses a blank
  # one.
  defp stated(%Result{model_text: text} = result, sentence) do
    if String.trim(text) == "", do: %{result | model_text: sentence}, else: result
  end

  defp normalize_result(%Result{} = result), do: Result.normalize(result)
  defp normalize_result(output) when is_binary(output) or is_list(output), do: Result.new(output)
  defp normalize_result(output), do: Result.new(inspect(output))

  defp prepend_output(%Result{} = result, ""), do: result

  defp prepend_output(%Result{} = result, output),
    do: %{result | model_text: output <> "\n\n" <> result.model_text}

  # Attachments are limited before the text is truncated, so a note naming an
  # image that was left out is subject to the same cap as everything else the
  # model reads.
  defp bound(%Result{} = result, max_bytes) do
    result = result |> Result.limit(max_bytes) |> Result.limit_attachments()
    %{result | model_text: truncate(result.model_text, max_bytes)}
  end

  @doc """
  Truncates `text` to `limit` bytes, leaving a marker saying what was cut.

  Keeps the head and the tail rather than just the head: the interesting part
  of a long build log is usually its ending, and the interesting part of a
  long file is usually its beginning.
  """
  @spec truncate(text :: String.t(), limit :: pos_integer()) :: String.t()
  def truncate(text, limit) when is_binary(text) and is_integer(limit) and limit > 0 do
    if byte_size(text) <= limit do
      text
    else
      half = div(limit, 2)
      cut = byte_size(text) - 2 * half

      # Sanitised per half, because cutting at a byte offset can land in the
      # middle of a codepoint and a transcript entry has to be encodable.
      head = text |> binary_part(0, half) |> sanitize()
      tail = text |> binary_part(byte_size(text) - half, half) |> sanitize()

      head <> "\n\n… [#{cut} bytes cut from the middle by lemieux] …\n\n" <> tail
    end
  end

  @doc """
  Splits `text` into lines the way every file-reading surface here does.

  One trailing newline is how a file ends, not a final empty line. Left in,
  every file reads as having one more line than it has, and every count the
  model reasons with is off by one.

  A `\r` before a newline is part of the line ending too, and is dropped.
  Shown, it reaches the model as an invisible character it cannot reproduce,
  and `Lemieux.Tools.Edit` matches CRLF files without it.
  """
  @spec split_lines(text :: String.t()) :: [String.t()]
  def split_lines(text) when is_binary(text) do
    text
    |> String.replace_suffix("\n", "")
    |> String.split("\n")
    |> Enum.map(&String.replace_suffix(&1, "\r", ""))
  end

  @doc """
  Numbers `lines`, counting from `offset`.

  The numbers are not decoration; they are how `Lemieux.Tools.Edit` and the
  model agree about where something is. Shared rather than reimplemented
  because a file that arrives through two different doors — read as a tool
  result, or attached to a prompt by an `@`-reference — has to be numbered
  identically through both. Two conventions would mean the model citing a
  line the editor cannot find.

  They are the file's own line numbers, not the window's, which is why
  `offset` exists. A window renumbered from one is a window that makes the
  model edit the wrong place.
  """
  @spec number_lines(lines :: [String.t()], offset :: pos_integer()) :: String.t()
  def number_lines(lines, offset) when is_list(lines) and is_integer(offset) and offset > 0 do
    lines
    |> Enum.with_index(offset)
    |> Enum.map_join("\n", fn {line, number} -> "#{number}\t#{line}" end)
  end

  @doc """
  Makes `text` safe to put in a transcript.

  Tool output is whatever a program wrote to a pipe, which is not necessarily
  UTF-8. Entries are JSON, and JSON encoding raises on an invalid byte
  sequence — so without this a command that emits one stray byte takes down
  the session that ran it, several layers away from the cause.
  """
  @spec sanitize(text :: binary()) :: String.t()
  def sanitize(text) when is_binary(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text)
  end
end
