defmodule Lemieux do
  @moduledoc ~S"""
  Lemieux is the Elixir runtime behind the lmx coding agent. It runs the model
  and tool loop itself and records every session as an append-only transcript
  you can resume, fork and replay.

  Models are called through `req_llm`, and the conversation is data your
  application owns: entries in a store you choose, events sent to processes
  you name. `lmx`, the terminal app, is a host built on exactly this API, with
  no privileged path into it.

  ## Try it without an API key

  The scripted provider answers instantly, so this runs anywhere. It is also
  a doctest, so it cannot drift from the code:

      iex> {:ok, _runtime} = Lemieux.Supervisor.start_link(name: MyApp.Agents)
      iex> dir = Path.join(System.tmp_dir!(), "lemieux-docs-#{System.unique_integer([:positive])}")
      iex> provider =
      ...>   Lemieux.Providers.Scripted.new([
      ...>     Lemieux.Providers.Scripted.complete("Hello from Lemieux")
      ...>   ])
      iex> {:ok, result} =
      ...>   Lemieux.run("Say hello",
      ...>     supervisor: MyApp.Agents,
      ...>     provider: provider,
      ...>     store: Lemieux.Store.JSONL.new(dir),
      ...>     model: "test:model",
      ...>     tools: []
      ...>   )
      iex> result.text
      "Hello from Lemieux"
      iex> File.rm_rf!(dir)
      iex> Supervisor.stop(MyApp.Agents)
      :ok

  Adding the dependency starts no Lemieux processes. A host mounts
  `Lemieux.Supervisor` in its own supervision tree,
  `{Lemieux.Supervisor, name: MyApp.Agents}`, and passes
  `supervisor: MyApp.Agents` to the functions here. With nothing mounted,
  `start_session/1` and `run/2` raise an `ArgumentError` that says so, and so
  does `resume_session/1` once it has found the transcript (an id nothing
  was written under returns `{:error, :not_found}` first). `session/2` and
  `sessions/1` do not check: they raise `Registry`'s own `ArgumentError`
  about an unknown registry. Lemieux's dependencies are
  ordinary OTP applications and start with the host as usual; the
  `Lemieux.Supervisor` documentation lists what that means.

  ## Use a real model

  Set the provider's key (for example `ANTHROPIC_API_KEY`), then swap the
  provider and model:

      Lemieux.run("Summarise README.md",
        supervisor: MyApp.Agents,
        provider: Lemieux.Providers.ReqLLM.new(),
        store: Lemieux.Store.JSONL.new("sessions"),
        model: "anthropic:claude-sonnet-5",
        tools: Lemieux.Tools.default(),
        max_requests: 20
      )

  `Lemieux.Tools.default/0` lets the model read, write and run commands with
  the permissions of the operating-system user running your application; see
  `Lemieux.Hooks` for approval policy and `Lemieux.Environment` for where
  commands run.

  ## Map of the API

  | To | Use |
  | --- | --- |
  | answer one prompt | `run/2` |
  | hold a conversation | `start_session/1`, then `Lemieux.Session.await/3` |
  | continue a stored one | `resume_session/1`; fork with `Lemieux.Transcript.fork/3` |
  | watch it live | `Lemieux.Session.subscribe/2` (events listed in `Lemieux.Session`) |
  | approve or deny tool calls | `Lemieux.Hooks` |
  | add a tool | `Lemieux.Tool` |
  | package reusable behaviour | `Lemieux.Extension` and `Lemieux.Harness` |
  | store transcripts elsewhere | `Lemieux.Store` |
  | test your host offline | `Lemieux.Testing` and `Lemieux.Providers.Scripted` |

  Guides: [First embedded agent](first-embedded-agent.md),
  [Embedding Lemieux](embedding.md) and [Customizing Lemieux](customization.md);
  the [documentation overview](guides.html) maps the rest. A module whose
  documentation opens with **Experimental.** may change in any 0.x release.

  ## Design

  Running the loop, rather than wrapping a vendor CLI and scraping its output,
  is what makes resume, fork and replay possible at all: they are reads over
  the transcript, and there is no way to reconstruct one from a subprocess's
  terminal output after the fact. Two boundaries hold the rest in place:

    * **Providers go through `req_llm`.** There are no hand-rolled provider
      adapters here. A new provider is that library's problem, not Lemieux's.
    * **The core takes no web or database dependency.** A host embeds it and
      attaches its own policy (tool approval, sandboxing, budgets) through
      hooks and extensions. Anything that would force a repo or an endpoint
      into this tree belongs in the host instead.
  """

  alias Lemieux.Harness
  alias Lemieux.ID.Shorthand
  alias Lemieux.OpenTelemetry
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Supervisor, as: Sup

  @version Mix.Project.config()[:version]

  @doc """
  The version of the lemieux library, as declared in `mix.exs`.

  Baked in at compile time rather than read from `Mix.Project` at runtime,
  because `Mix` is not included in the standalone `lmx` release.
  """
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  Starts a session under a mounted runtime.

  Takes `Lemieux.Session.start_link/1`'s options, plus `:supervisor` naming
  the mount to start it under. Sessions are started here rather than by a host
  calling `Lemieux.Session.start_link/1` directly so that they end up under
  the runtime's `DynamicSupervisor` — a session started outside it is linked
  to whoever started it, which for a CLI or a web request means the agent dies
  when its caller does.

  `:harness` takes a `Lemieux.Harness`, usually one `Lemieux.Harness.assemble/2`
  built from extensions. Its `Lemieux.Harness.session_options/1` are merged
  **under** the other options, so an option named in the keyword wins over
  the same field on the harness. The harness is behaviour that arrived
  through code — a dependency's opinion, a profile's tuning — and the
  keyword is the host speaking now, about this session; when the two
  disagree the host is right, and the alternative would let an extension
  quietly override a budget the host set for one call. The exception is
  `:harness_context`, whose maps are merged key by key with the keyword's
  winning on conflict, because a host adding its own correlation ids should
  not thereby drop the provenance the harness recorded.

  Raises `ArgumentError` when no runtime is mounted under `:supervisor`
  (`Lemieux.Supervisor` when it is not given), when `:provider` or `:store` is
  missing or is not a `{module, state}` pair, or when a session that is not
  continuing a transcript has no `:model`. These are checked here, in the
  caller, for the reason `Lemieux.Supervisor.start_link/1` checks its own
  options there: the same mistakes found inside the session's `init` come back
  as an exit about `...SessionSupervisor` or an `{:error, {%KeyError{}, stack}}`
  that names neither the option nor the fix.
  """
  @spec start_session(opts :: keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(opts \\ []) do
    {harness, opts} = Keyword.pop(opts, :harness)
    opts = with_harness(opts, harness)
    supervisor = Keyword.get(opts, :supervisor, Sup)

    options!(opts)
    mounted!(supervisor)

    # OTel context is process-local. Capture it before DynamicSupervisor moves
    # startup into the session process; Session binds it only after successful
    # initialization and does not retain the opaque context in its state or
    # transcript.
    parent_contexts = OpenTelemetry.capture_contexts()

    DynamicSupervisor.start_child(
      Sup.session_supervisor(supervisor),
      {Session,
       Keyword.merge(opts,
         supervisor: supervisor,
         open_telemetry_parent_contexts: parent_contexts
       )}
    )
  end

  @doc """
  Starts a session that continues a stored transcript.

  Reads `:resume`'s entries from the store and starts a session under that
  same id, so the conversation carries on in the file it was already in.

  **The model is given the conversation, not a handle to it.** That is the
  difference between owning the loop and driving someone else's: a resumed
  session rebuilds the exact context from entries lemieux wrote, rather than
  handing a provider an opaque id and trusting a store nobody here can read.
  It is also why a transcript copied to another machine, or forked with
  `Lemieux.Transcript.fork/3`, resumes just as well as the original.

  `:resume` may be an id or the shorthand `Lemieux.ID.Shorthand` derives from
  one — a session is resumed by whichever of its two names the caller has.

  `:harness` is accepted as in `start_session/1`, with the same precedence.
  A harness field that is set replaces what the transcript recorded, exactly
  as the keyword option would; one left unset lets the transcript speak.
  `Lemieux.Harness` says how a host seeds the harness from the transcript
  when it wants extensions to compose over the recorded prompt and catalog
  rather than replace them.

  Returns `{:error, :not_found}` when nothing was ever written under that id,
  and `{:error, {:ambiguous, ids}}` for a shorthand two stored sessions share.
  Raises `ArgumentError` for the mistakes `start_session/1` raises for, except
  that `:model` may be left to the transcript.
  """
  @spec resume_session(opts :: keyword()) :: DynamicSupervisor.on_start_child()
  def resume_session(opts) do
    {reference, opts} = Keyword.pop!(opts, :resume)
    store = pair!(opts, :store)

    with {:ok, id} <- Shorthand.resolve(store, reference),
         {:ok, entries} <- Store.read(store, id) do
      start_session(Keyword.merge(opts, id: id, entries: entries))
    end
  end

  @doc """
  Runs one prompt in a session of its own and returns what it produced.

  The shortest complete embedding: start a session with `opts` (or resume
  one, when `:resume` is among them), send `text`, wait for the work to
  finish, and stop the session again. The result is
  `Lemieux.Session.await/3`'s — the final answer's text, the stop reason,
  the prompt's usage and every entry it wrote — and the transcript stays in
  the store, so the same session can be resumed later.

  The session runs under a mounted runtime, so the host's supervision tree
  holds one first:

      # In MyApp.Application.start/2:
      children = [{Lemieux.Supervisor, name: MyApp.Agents}]

      # Then, anywhere in the application:
      {:ok, result} =
        Lemieux.run("Summarise README.md",
          supervisor: MyApp.Agents,
          provider: Lemieux.Providers.ReqLLM.new(),
          store: Lemieux.Store.JSONL.new("sessions"),
          model: "anthropic:claude-sonnet-5"
        )

      result.text

  Besides the session options: `:timeout` and `:on_event` as
  `Lemieux.Session.await/3` takes them, and `:keep_session` to leave the
  session running afterwards — `session/2` finds it by `result.session_id`.
  A session that is not kept is stopped even when the wait times out.
  Raises `ArgumentError` for the mistakes `start_session/1` raises for.
  """
  @spec run(text :: String.t(), opts :: keyword()) ::
          {:ok, Lemieux.Session.Await.result()} | {:error, term()}
  def run(text, opts) when is_binary(text) and is_list(opts) do
    {await_opts, opts} = Keyword.split(opts, [:timeout, :on_event])
    {keep?, opts} = Keyword.pop(opts, :keep_session, false)
    start = if Keyword.has_key?(opts, :resume), do: &resume_session/1, else: &start_session/1

    with {:ok, session} <- start.(opts) do
      try do
        Session.await(session, text, await_opts)
      after
        if not keep?, do: stop(session, Keyword.get(opts, :supervisor, Sup))
      end
    end
  end

  defp stop(session, supervisor) do
    _ = DynamicSupervisor.terminate_child(Sup.session_supervisor(supervisor), session)
    :ok
  end

  # Nothing starts on its own, so the commonest first mistake is calling this
  # before mounting anything, which otherwise surfaces as a GenServer exit
  # about a process named `...SessionSupervisor` the caller never heard of.
  defp mounted!(supervisor) do
    if is_nil(Process.whereis(Sup.session_supervisor(supervisor))) do
      raise ArgumentError,
            "no Lemieux runtime is mounted as #{inspect(supervisor)}#{default_mount(supervisor)}: " <>
              "add {Lemieux.Supervisor, name: #{inspect(supervisor)}} to your supervision tree, " <>
              "or call Lemieux.Supervisor.start_link(name: #{inspect(supervisor)}) first"
    end

    :ok
  end

  defp default_mount(Sup), do: " (the default when :supervisor is not given)"
  defp default_mount(_supervisor), do: ""

  defp options!(opts) do
    pair!(opts, :provider)
    pair!(opts, :store)
    model!(opts)
  end

  # Providers and stores carry credentials and connections in their state, so
  # a wrong value is described by its shape, never inspected into a message
  # that may end up in a log.
  defp pair!(opts, key) do
    case Keyword.get(opts, key) do
      {module, _state} = pair when is_atom(module) and not is_nil(module) ->
        pair

      nil ->
        raise ArgumentError, "a session needs #{inspect(key)}: #{example(key)}"

      module when is_atom(module) ->
        raise ArgumentError,
              "#{inspect(key)} must be a {module, state} pair, not the module " <>
                "#{inspect(module)} itself: #{example(key)}"

      _other ->
        raise ArgumentError, "#{inspect(key)} must be a {module, state} pair: #{example(key)}"
    end
  end

  defp example(:provider),
    do:
      "build one with Lemieux.Providers.ReqLLM.new(), or Lemieux.Providers.Scripted.new(script) " <>
        "in a test"

  defp example(:store), do: ~s|build one with Lemieux.Store.JSONL.new("sessions")|

  # A session continuing a transcript takes its model from the transcript
  # unless one is passed, and the session says so if that transcript has none.
  defp model!(opts) do
    case {Keyword.get(opts, :model), Keyword.get(opts, :entries, [])} do
      {nil, []} ->
        raise ArgumentError,
              ~s|a new session needs :model, a req_llm model specification such as | <>
                ~s|"anthropic:claude-sonnet-5"|

      _given_or_recorded ->
        :ok
    end
  end

  defp with_harness(opts, nil), do: opts

  defp with_harness(opts, %Harness{} = harness) do
    from_harness = Harness.session_options(harness)

    context =
      deep_merge(
        Keyword.get(from_harness, :harness_context, %{}),
        Keyword.get(opts, :harness_context, %{})
      )

    # A replacement catalog is a new host decision. Carrying the previous
    # catalog's reconstruction notes would resurrect it on the next resume.
    context =
      if Keyword.has_key?(opts, :tools), do: Map.delete(context, "assembly"), else: context

    merged = Keyword.merge(from_harness, opts)

    if context == %{},
      do: Keyword.delete(merged, :harness_context),
      else: Keyword.put(merged, :harness_context, context)
  end

  defp with_harness(_opts, other) do
    raise ArgumentError, ":harness must be a %Lemieux.Harness{}; got #{inspect(other)}"
  end

  defp deep_merge(%{} = under, %{} = over) do
    Map.merge(under, over, fn
      _key, %{} = a, %{} = b -> deep_merge(a, b)
      _key, _a, b -> b
    end)
  end

  @doc """
  Finds a running session by id.
  """
  @spec session(supervisor :: atom(), id :: String.t()) :: {:ok, pid()} | :error
  def session(supervisor \\ Sup, id) when is_binary(id) do
    case Registry.lookup(Sup.registry(supervisor), id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :error
    end
  end

  @doc """
  Lists the sessions running under a mounted runtime.
  """
  @spec sessions(supervisor :: atom()) :: [{String.t(), pid()}]
  def sessions(supervisor \\ Sup) do
    Registry.select(Sup.registry(supervisor), [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end
end
