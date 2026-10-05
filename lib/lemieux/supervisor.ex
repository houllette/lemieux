defmodule Lemieux.Supervisor do
  @moduledoc """
  The supervision tree a host mounts to run lemieux.

  **lemieux has no `mod:` entry in `mix.exs`, so adding the dependency starts
  no Lemieux processes.** A host puts this supervisor into its own tree and
  owns the lifecycle:

      children = [
        {Lemieux.Supervisor, name: MyApp.Agents}
      ]

  Lemieux's dependencies are ordinary OTP applications, and they do start
  with the host. `req_llm` starts its HTTP pool and task supervisor, and at
  boot it loads `./.env` from the current working directory into the
  operating-system environment unless the host sets
  `config :req_llm, load_dotenv: false`. Loading that file runs any `$(...)`
  command substitution in it, so a host that may start in a directory it
  does not trust, as an installed command-line tool does, turns it off; the
  installed `lmx` does. What the missing `mod:` guarantees is narrower, and it
  is the part that matters here: no Lemieux process or registered name exists
  until a host mounts this tree.

  The obvious alternative — an `Application` callback that boots itself the
  moment the app is loaded — was rejected because it takes the decision away
  from the embedder. A host that wants two isolated runtimes, or wants none
  until a request arrives, cannot get there from a self-starting singleton,
  and a library that starts processes on load is one an embedder has to fight
  rather than configure. `lmx` mounts this the same way any other host does;
  the CLI gets no privileged path.

  Everything lemieux supervises hangs off here, which is what makes running
  more than one independent runtime in a single VM a matter of passing a
  different `:name`.

  ## Options

    * `:name` — the mount point; every child's name is derived from it.
    * `:provider_limiter` — provider admission. A keyword list configures the
      shipped `Lemieux.ProviderLimiter`; `{module, opts}` starts `module`, a
      `Lemieux.Provider.Admission` implementation, in its place. Either way
      the child is named `provider_limiter/1` and sessions find the pair to
      call through `provider_admission/1`. The keyword list passes through to
      the limiter whole, `clock:` included: `provider_limiter: [clock: clock]`
      with a `Lemieux.Clock.Manual` drives its cooldowns and refill windows
      in a test without waiting in real time.
    * `:subagents` — options for `Lemieux.Subagent.Admission`, including
      `:max_active_runtime` and `:max_active_root`.

  ## What is deliberately not here

  Sizing `req_llm`'s shared HTTP stream pool used to happen in `init/1`,
  on the grounds that the concurrency needing it is declared here. It does
  not any more. `Lemieux.ProviderPool.ensure/1` writes another application's
  environment and may restart that application, and a library doing either
  from inside a host's supervision tree is doing it underneath whatever else
  that host has in flight. The host makes the call before it mounts — `lmx`
  does in `Lemieux.CLI.configure/0` — or configures `:req_llm`'s pool itself.
  Passing `:provider_pool` or `:max_concurrent_streams` here is an error
  rather than a silent no-op, so a host that relied on the old behaviour
  finds out at mount rather than when its children queue.
  """

  use Supervisor

  @pool_options [:provider_pool, :max_concurrent_streams]

  @doc """
  Starts the tree.

  Accepts `:name` (defaulting to this module) so a host can mount more than
  one independent runtime; every other option is passed through to `init/1`.
  Options are validated here, in the caller, so a mistake reads as an
  `ArgumentError` at the call site rather than as a supervisor that failed to
  start for a reason buried in a `{:shutdown, ...}` tuple.
  """
  @spec start_link(opts :: keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    reject_pool_options!(opts)
    _validated = admission_spec!(opts)
    Supervisor.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  @doc """
  The registry sessions register their ids in, for a runtime mounted as `name`.
  """
  @spec registry(name :: atom()) :: atom()
  def registry(name \\ __MODULE__), do: Module.concat(name, Registry)

  @doc """
  The `Task.Supervisor` provider streams and tool calls run under.
  """
  @spec task_supervisor(name :: atom()) :: atom()
  def task_supervisor(name \\ __MODULE__), do: Module.concat(name, TaskSupervisor)

  @doc "The registry of session-scoped background commands."
  @spec background_registry(name :: atom()) :: atom()
  def background_registry(name \\ __MODULE__), do: Module.concat(name, BackgroundRegistry)

  @doc "The `DynamicSupervisor` background commands run under."
  @spec background_supervisor(name :: atom()) :: atom()
  def background_supervisor(name \\ __MODULE__), do: Module.concat(name, BackgroundSupervisor)

  @doc """
  The name the mount-local provider admission process is registered under.

  Whatever module the mount chose runs under this name; `provider_admission/1`
  says which module, and is what a session should call with.
  """
  @spec provider_limiter(name :: atom()) :: atom()
  def provider_limiter(name \\ __MODULE__), do: Module.concat(name, ProviderLimiter)

  @doc """
  The provider admission a session of the runtime mounted as `name` checks
  leases out from: a `{module, ref}` pair for `Lemieux.Provider.Admission`.

  Read from `:persistent_term`, where `init/1` recorded the module the mount
  chose. A mount is a rare event and every provider request reads this, which
  is exactly the trade `:persistent_term` makes. A name nothing has recorded
  answers the shipped limiter under the derived child name, so a test that
  starts `Lemieux.ProviderLimiter` by hand under that name keeps working.
  """
  @spec provider_admission(name :: atom()) :: Lemieux.Provider.Admission.t()
  def provider_admission(name \\ __MODULE__) do
    :persistent_term.get(admission_key(name), {Lemieux.ProviderLimiter, provider_limiter(name)})
  end

  @doc """
  The `DynamicSupervisor` sessions are started under.
  """
  @spec session_supervisor(name :: atom()) :: atom()
  def session_supervisor(name \\ __MODULE__), do: Module.concat(name, SessionSupervisor)

  @doc "The runtime-wide subagent admission coordinator."
  @spec subagent_admission(name :: atom()) :: atom()
  def subagent_admission(name \\ __MODULE__), do: Module.concat(name, SubagentAdmission)

  @doc "The `DynamicSupervisor` foreground subagent groups are started under."
  @spec subagent_group_supervisor(name :: atom()) :: atom()
  def subagent_group_supervisor(name \\ __MODULE__),
    do: Module.concat(name, SubagentGroupSupervisor)

  @doc """
  The `DynamicSupervisor` evaluation nodes are started under.

  Separate from the session supervisor because the two die differently. A
  `Lemieux.Eval.Sandbox` owns an operating-system process, and one that
  crashes should be restartable without anything having happened to the
  session whose work it was doing — the transcript is the durable thing, and
  a node is a resource that can be replaced.
  """
  @spec sandbox_supervisor(name :: atom()) :: atom()
  def sandbox_supervisor(name \\ __MODULE__), do: Module.concat(name, SandboxSupervisor)

  @impl Supervisor
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    {admission, admission_opts} = admission_spec!(opts)

    # Recorded before the child starts, so nothing can read the previous
    # mount's answer between the two. Always written, even for the default: a
    # name a custom module once ran under must not keep answering that module
    # after it is re-mounted with the shipped one.
    :persistent_term.put(admission_key(name), {admission, provider_limiter(name)})

    # Every child's name is derived from the mount's, which is what makes two
    # runtimes in one VM a matter of passing a different :name rather than a
    # fight over globals.
    children = [
      {Registry, keys: :unique, name: registry(name)},
      {admission, Keyword.put(admission_opts, :name, provider_limiter(name))},
      # Provider streams and tool calls run here rather than under the session
      # itself. A session that linked its own work would die with a crashing
      # tool, taking a transcript's worth of unpersisted state with it; here a
      # crash arrives as a message the session can turn into an entry.
      {Task.Supervisor, name: task_supervisor(name)},
      {Registry, keys: :unique, name: background_registry(name)},
      {DynamicSupervisor, name: background_supervisor(name), strategy: :one_for_one},
      {Lemieux.Subagent.Admission,
       Keyword.put(Keyword.get(opts, :subagents, []), :name, subagent_admission(name))},
      {DynamicSupervisor, name: session_supervisor(name), strategy: :one_for_one},
      {DynamicSupervisor, name: subagent_group_supervisor(name), strategy: :one_for_one},
      # Nothing is started here until a session actually asks to evaluate
      # Elixir, which most never do — see `Lemieux.Tools.Eval` on why that
      # tool is not in the default set.
      {DynamicSupervisor, name: sandbox_supervisor(name), strategy: :one_for_one}
    ]

    # :one_for_one, not :rest_for_one: sessions hold their transcripts in
    # memory, so restarting the whole tree because the registry died would
    # lose live work. Each child is independent of the others' state.
    Supervisor.init(children, strategy: :one_for_one)
  end

  defp admission_key(name), do: {__MODULE__, name, :provider_admission}

  defp admission_spec!(opts) do
    case Keyword.get(opts, :provider_limiter, []) do
      limiter_opts when is_list(limiter_opts) ->
        {Lemieux.ProviderLimiter, limiter_opts}

      {module, module_opts} when is_atom(module) and is_list(module_opts) ->
        {module, module_opts}

      other ->
        raise ArgumentError,
              ":provider_limiter must be a keyword list for Lemieux.ProviderLimiter or " <>
                "{module, opts} for a Lemieux.Provider.Admission implementation, got: " <>
                inspect(other)
    end
  end

  defp reject_pool_options!(opts) do
    case Enum.find(@pool_options, &Keyword.has_key?(opts, &1)) do
      nil ->
        :ok

      key ->
        raise ArgumentError,
              "#{inspect(key)} is no longer a Lemieux.Supervisor option: the provider stream " <>
                "pool is not sized on mount. Call Lemieux.ProviderPool.ensure/1 from the host " <>
                "before mounting, or configure :req_llm's pool yourself"
    end
  end
end
