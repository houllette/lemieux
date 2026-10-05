defmodule Lemieux.Eval.Sandbox do
  @moduledoc """
  A separate BEAM node for a session to evaluate Elixir on.

  One of these belongs to one session, and it exists so that
  `Lemieux.Tools.Eval` never runs model-written code in the VM holding the
  transcript, the credentials and the loop.

  ## Why a whole node, and not a process

  A process is not an isolation boundary on the BEAM in the way people
  sometimes hope. Code running in one can read every ETS table the VM has,
  reach any registered name, `:sys.get_state/1` any GenServer, call
  `Application.get_all_env/1` on any application, and `Code.compile_string/1`
  a replacement for any module — including lemieux's own. Limits on heap and
  reductions bound how *much* it does, not *what*.

  So the boundary is the VM. On the far side, `Lemieux.Eval.Runner` is
  looking at its own ETS, its own registered names, its own applications, and
  cannot see the session that asked it anything. A prompt injected into a
  README can still do everything a shell command could do to the filesystem —
  it is a coding agent, that is the job — but it cannot read the API key held
  in this VM's memory, cannot rewrite the tool that is about to report on it,
  and cannot take the session down.

  ## Why it needs no distribution

  `:peer` is given `connection: :standard_io`, so the node is spoken to over a
  pipe rather than over Erlang distribution. That is not a detail: it means
  `lmx` does not have to become a distributed node to gain this tool, which
  would otherwise mean starting epmd, holding a cookie, and opening a port on
  a machine where nobody asked for one. Distribution is what the *attach* case
  needs, and it stays that case's problem.

  ## What is not claimed

  This is an isolation boundary, not a sandbox. The evaluating node runs as
  the same operating-system user, with the same filesystem and the same
  network. Confining *those* is the host's job and the operating system's —
  see `Lemieux.Tools.Bash`, which says the same thing about shell commands and
  for the same reason. What this buys is that the blast radius of a bad
  evaluation is a node that can be thrown away.
  """

  use GenServer, restart: :temporary

  alias Lemieux.Environment
  alias Lemieux.Environment.Credentials
  alias Lemieux.Eval.Attach
  alias Lemieux.Eval.Runner
  alias Lemieux.Supervisor, as: Sup

  # Long enough for a compile or a test run to finish, short enough that a
  # session does not appear to have hung. `Lemieux.Tools.Eval` documents why
  # this is not the model's to choose.
  @timeout :timer.minutes(2)

  # 256MB on a 64-bit VM, matching the order of what beamcore allows an
  # evaluation. Big enough to read a large file into memory and work on it,
  # small enough that a runaway list comprehension dies quickly.
  @max_heap_words 32_000_000

  @max_output 32_000

  @doc """
  Evaluates `code` for the session named by `context`, starting a node if this
  is the first time it has asked.

  Started on demand rather than with the session, because most sessions never
  use this tool and a BEAM node costs a few hundred milliseconds and a few
  megabytes to have.
  """
  @spec eval(code :: binary(), context :: map()) ::
          {:ok, binary()} | {:error, binary()}
  def eval(code, context) do
    # Asked before anything is started, so a malformed packaged host gets a
    # sentence rather than a supervisor crash report wrapped around one.
    with :ok <- reachable(),
         {:ok, sandbox} <- start(context) do
      # `:infinity` here, with the real bound on the far side: the runner
      # kills what it is running and reports it, and a caller that gave up
      # first would leave the evaluation going with nobody to hear about it.
      GenServer.call(sandbox, {:eval, code, context.cwd}, :infinity)
    end
  end

  defp start(context) do
    name = via(context)

    # The node is a process this machine starts beside the session's
    # environment, so it inherits the VM's variables unless told otherwise —
    # and `System.get_env("OPENAI_API_KEY")` is one line of Elixir. It gets the
    # environment's credential policy, the same one `bash` runs under.
    credentials = context |> Map.get(:environment) |> credentials()

    case DynamicSupervisor.start_child(
           Sup.sandbox_supervisor(context.supervisor),
           {__MODULE__, name: name, session_id: context.session_id, credentials: credentials}
         ) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, "could not start an evaluation node: #{inspect(reason)}"}
    end
  end

  # A context built by hand for this tool alone may carry no environment; the
  # node then inherits, as it always did.
  defp credentials(nil), do: :inherit
  defp credentials(environment), do: Environment.credentials(environment)

  @doc """
  Points this session's evaluation at a node somebody else is running.

  Everything the model evaluates from now on happens there, until `detach/1`.
  The node lemieux started stays alive and keeps whatever was defined on it,
  because attaching is usually a detour rather than a decision.
  """
  @spec attach(context :: map(), target :: String.t()) :: {:ok, node()} | {:error, binary()}
  def attach(context, target) do
    with :ok <- reachable(),
         {:ok, sandbox} <- start(context),
         {:ok, node} <- Attach.attach(target) do
      GenServer.call(sandbox, {:attached, node})
    end
  end

  @doc """
  Goes back to evaluating on the node lemieux started.
  """
  @spec detach(context :: map()) :: :ok | {:error, binary()}
  def detach(context) do
    with :ok <- reachable(),
         {:ok, sandbox} <- start(context) do
      GenServer.call(sandbox, :detached)
    end
  end

  @doc """
  Where this session is evaluating: `nil` for its own node, or somebody
  else's.
  """
  @spec target(context :: map()) :: node() | nil
  def target(context) do
    case Registry.lookup(Sup.registry(context.supervisor), {:elixir_sandbox, context.session_id}) do
      [{sandbox, _value}] -> GenServer.call(sandbox, :target)
      [] -> nil
    end
  end

  defp via(context),
    do:
      {:via, Registry, {Sup.registry(context.supervisor), {:elixir_sandbox, context.session_id}}}

  @doc """
  Starts a node.

  The three limits are options rather than constants so that a caller which
  knows better can say so — and so the tests can prove the timeout fires
  without waiting #{div(@timeout, 60_000)} minutes to watch it.
  """
  @spec start_link(opts :: keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      session_id: Keyword.fetch!(opts, :session_id),
      credentials: Keyword.get(opts, :credentials, :inherit),
      timeout: Keyword.get(opts, :timeout, @timeout),
      max_heap_words: Keyword.get(opts, :max_heap_words, @max_heap_words),
      max_output: Keyword.get(opts, :max_output, @max_output),
      peer: nil,
      node: nil,
      # `nil` while evaluating on our own node. Set to somebody else's node
      # once a person has attached to it — see `Lemieux.Eval.Attach`.
      attached: nil
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl GenServer
  def handle_continue(:boot, state) do
    case boot(state.credentials) do
      {:ok, peer, node} ->
        {:noreply, %{state | peer: peer, node: node}}

      {:error, reason} ->
        # Stopping rather than retrying: the caller is a tool call waiting for
        # an answer, and it is owed the reason rather than a hang.
        {:stop, {:no_node, reason}, state}
    end
  end

  # The code paths are handed over so the node can load Elixir itself, and
  # `Lemieux.Eval.Runner` with it. That does mean the node *could* load
  # lemieux's modules — but code is not state: what it must not reach is this
  # VM's memory, and a separate VM is exactly what stops that.
  #
  # Withheld variables are blanked, not unset: `:peer` takes `{name, value}`
  # strings only. An empty key is still no key.
  defp boot(credentials) do
    env =
      credentials
      |> Credentials.overrides()
      |> Enum.map(fn {name, false} -> {String.to_charlist(name), ~c""} end)

    case :peer.start_link(%{connection: :standard_io, args: [~c"-pa" | paths()], env: env}) do
      {:ok, peer, node} -> started(peer, node)
      {:error, reason} -> {:error, reason}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Whether a node started from here could load Elixir at all.

  A custom packaged host can expose archive members rather than real code
  directories. A second BEAM handed those paths starts, finds no `elixir.app`,
  and fails at the first `defmodule` with an error about an ETS table — which
  is a long way from the cause. Official native OTP releases expose directories.

  Checked up front so the answer is a sentence rather than that.
  """
  @spec reachable() :: :ok | {:error, binary()}
  def reachable do
    case :code.lib_dir(:elixir) do
      {:error, _reason} -> {:error, unreachable()}
      path -> if File.dir?(path), do: :ok, else: {:error, unreachable()}
    end
  end

  defp unreachable do
    "the elixir tool needs to start a second BEAM node, and this build cannot: " <>
      "its code path points inside an archive rather than at directories, so " <>
      "the node it started would have no Elixir to run. Use the official lmx " <>
      "release, a source checkout, or a host with a standard OTP release " <>
      "layout. Every other tool is unaffected."
  end

  # Only paths that are real directories. An archive's members are not, and a
  # node given one spends its startup failing to read it.
  defp paths, do: Enum.filter(:code.get_path(), &File.dir?/1)

  # Elixir has to be *started*, not merely reachable. A node given the code paths
  # can already evaluate an expression, which is what makes this easy to miss — but
  # `defmodule` reads `:elixir_config`, an ETS table the application creates when it
  # boots, so defining a module where nobody started `:elixir` fails with a missing
  # table and no hint about what is wrong.
  defp started(peer, node) do
    case :peer.call(peer, :application, :ensure_all_started, [:elixir], :timer.seconds(30)) do
      {:ok, _apps} -> {:ok, peer, node}
      {:error, reason} -> {:error, {:elixir_would_not_start, reason}}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @impl GenServer
  def handle_call({:attached, node}, _from, state) do
    # Monitored, so that an application which is stopped or restarted while
    # attached takes the session back to its own node rather than leaving it
    # calling a node that is gone.
    Node.monitor(node, true)

    {:reply, {:ok, node}, %{state | attached: node}}
  end

  def handle_call(:detached, _from, state) do
    if state.attached, do: Node.monitor(state.attached, false)

    {:reply, :ok, %{state | attached: nil}}
  end

  def handle_call(:target, _from, state), do: {:reply, state.attached, state}

  def handle_call({:eval, code, cwd}, _from, state) do
    opts = [
      timeout: state.timeout,
      max_heap_words: state.max_heap_words,
      max_output: state.max_output,
      cwd: cwd
    ]

    # The call is given headroom over the evaluation's own timeout, so that a
    # runner which stopped its work on time still gets to say so. Losing the
    # race here would report a node problem where there was an ordinary
    # timeout, which sends the reader looking in the wrong place.
    {:reply, call(state, code, opts), state}
  end

  defp call(state, code, opts) do
    case route(state, code, opts) do
      {:ok, %{output: output, result: result}} -> {:ok, said(output) <> result}
      {:error, %{output: output, message: message}} -> {:error, said(output) <> message}
    end
  catch
    :exit, {:timeout, _call} ->
      {:error, "the evaluation node stopped answering, and has been left running"}

    kind, reason ->
      {:error, "the evaluation node failed: #{inspect({kind, reason})}"}
  end

  # Two transports for one call, because the two nodes are reached differently
  # and only one of them is ours: `:peer` speaks over the pipe it was started
  # with, and somebody else's node is reached over distribution.
  defp route(%{attached: nil} = state, code, opts),
    do: :peer.call(state.peer, Runner, :eval, [code, opts], state.timeout + :timer.seconds(10))

  defp route(%{attached: node} = state, code, opts) do
    # `:cwd` is dropped: the application's working directory is its own, and
    # moving it under a running server is a change to that server rather than
    # to an evaluation.
    :erpc.call(
      node,
      Runner,
      :eval,
      [code, Keyword.delete(opts, :cwd)],
      state.timeout + :timer.seconds(10)
    )
  end

  @impl GenServer
  def handle_info({:nodedown, node}, %{attached: node} = state) do
    {:noreply, %{state | attached: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp said(""), do: ""
  defp said(output), do: output <> "\n"

  @impl GenServer
  def terminate(_reason, %{peer: peer}) when is_pid(peer) do
    # Best effort: the node is an operating-system process, and leaving one
    # behind per session is the kind of leak that is only noticed at the
    # hundredth. It dies with us anyway, having been started with a link.
    :peer.stop(peer)
  catch
    _kind, _reason -> :ok
  end

  def terminate(_reason, _state), do: :ok
end
