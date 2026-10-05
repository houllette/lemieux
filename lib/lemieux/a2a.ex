defmodule Lemieux.A2A do
  @moduledoc """
  Explicit peer communication over A2A 1.0 JSON-RPC or trusted Erlang
  distribution. Asking never starts a server. Hosts mount `A2A.Server` to
  export a bounded read-only repository service and `A2A.Handler` to attach
  their authenticated HTTP endpoint. See `docs/a2a.md` for policy and recovery.

  Every operation forwards transport options such as HTTP authentication,
  timeout and history length. Existing custom transports with the original
  callbacks continue to work; optional callbacks add listing and subscription.
  Cookie-sharing BEAM peers have arbitrary RPC authority, not task isolation.
  """

  alias Lemieux.A2A.Transport.Distribution
  alias Lemieux.A2A.Transport.HTTP

  @typedoc """
  Where another agent is.

  An atom is a BEAM node; a string beginning `http` is a URL. Anything else
  is an error rather than a guess — unless a binding given in `:transports`
  claims it, in which case it is whatever that binding says it is, which is
  why the type is open.
  """
  @type address :: term()

  # The options the router reads and the binding never sees.
  @routing [:transport, :transports]

  @doc """
  The bindings an address is matched against, in order.

  Distribution, then HTTP: each claims the shape it owns through `handles?/1`,
  and the two shapes do not overlap, so the order is not load-bearing today.
  It is a list rather than a set so that a host putting its own binding first
  can shadow a built-in one for an address both would take.
  """
  @spec transports() :: [module()]
  def transports, do: [Distribution, HTTP]

  @doc """
  Asks the agent at `address` something, and waits for the answer.

  Returns the task in whatever state it reached. That is not always an ending:
  an agent that needs something back answers `:input_required`, and the way to
  continue is to ask again with the same task id —

      {:ok, asking} = Lemieux.A2A.ask(agent, "is it deployed?")
      asking.state    #=> :input_required
      asking.message  #=> "which environment?"

      {:ok, done} = Lemieux.A2A.ask(agent, %{"taskId" => asking.id, "parts" => [%{"text" => "production"}]})

  ## Options

    * `:stream` — a pid to send `{:a2a, task_id, event}` to as the answer is
      written. Distribution only; over HTTP the events are on the response.
    * `:timeout` — how long to wait.
    * `:transport`, `:transports` — which binding, as described in the
      moduledoc.
  """
  @spec ask(address :: address(), message :: String.t() | map(), opts :: keyword()) ::
          {:ok, Lemieux.A2A.Task.t() | map()} | {:error, String.t()}
  def ask(address, message, opts \\ []) do
    with {:ok, transport} <- transport(address, opts) do
      transport.send_message(address, message, Keyword.drop(opts, @routing))
    end
  end

  @doc """
  What an agent says it is, and what it will answer.

  Worth reading before asking: `skills` is what the agent has undertaken to
  do, and an agent that does not offer what you need is one you can skip
  without spending a turn on it.

  `opts` are `:transport` and `:transports`, as described in the moduledoc.
  """
  @spec card(address :: address(), opts :: keyword()) ::
          {:ok, Lemieux.A2A.Card.t()} | {:error, String.t()}
  def card(address, opts \\ []) do
    with {:ok, transport} <- transport(address, opts),
         do: invoke(transport, :card, [address], opts)
  end

  @doc """
  Where a task got to, without waiting on it.

  `opts` are `:transport` and `:transports`, as described in the moduledoc.
  """
  @spec task(address :: address(), task_id :: String.t(), opts :: keyword()) ::
          {:ok, Lemieux.A2A.Task.t()} | {:error, String.t()}
  def task(address, task_id, opts \\ []) do
    with {:ok, transport} <- transport(address, opts),
         do: invoke(transport, :get_task, [address, task_id], opts)
  end

  @doc """
  Asks an agent to stop working on something.

  `opts` are `:transport` and `:transports`, as described in the moduledoc.
  """
  @spec cancel(address :: address(), task_id :: String.t(), opts :: keyword()) ::
          {:ok, Lemieux.A2A.Task.t()} | {:error, String.t()}
  def cancel(address, task_id, opts \\ []) do
    with {:ok, transport} <- transport(address, opts),
         do: invoke(transport, :cancel_task, [address, task_id], opts)
  end

  @doc """
  The connected peers actually serving A2A, as addresses.

  Distribution only. The host connects trusted nodes explicitly; this does
  not create atoms from epmd advertisements or probe unrelated runtimes.
  """
  @spec nearby() :: [node()]
  def nearby do
    Node.list()
    |> Enum.filter(fn peer -> match?({:ok, _}, Distribution.card(peer, timeout: 1_000)) end)
  end

  @doc "Lists tasks visible to this caller, with bounded pagination."
  @spec list(address :: address(), params :: map(), opts :: keyword()) :: tuple()
  def list(address, params \\ %{}, opts \\ []) do
    with {:ok, transport} <- transport(address, opts),
         do: invoke(transport, :list_tasks, [address, params], opts)
  end

  @doc "Subscribes or reconnects to an existing task; HTTP blocks until interruption or completion."
  @spec subscribe(address :: address(), task_id :: String.t(), opts :: keyword()) :: tuple()
  def subscribe(address, task_id, opts \\ []) do
    with {:ok, transport} <- transport(address, opts),
         do: invoke(transport, :subscribe, [address, task_id], opts)
  end

  defp invoke(module, function, args, opts) do
    cond do
      function_exported?(module, function, length(args) + 1) ->
        apply(module, function, args ++ [Keyword.drop(opts, @routing)])

      function_exported?(module, function, length(args)) ->
        apply(module, function, args)

      true ->
        {:error, "transport does not support #{function}"}
    end
  end

  # The address is the routing decision, and it is made once here rather than
  # at each call site: the bindings are asked in order, and the first to claim
  # the address has it. By default that means a node is distribution and a
  # URL is JSON-RPC; the shapes themselves live in the bindings, so a third
  # one is one more entry in the list and no clause here.
  defp transport(address, opts) do
    case Keyword.fetch(opts, :transport) do
      {:ok, module} when is_atom(module) ->
        {:ok, module}

      :error ->
        transports = Keyword.get(opts, :transports, transports())

        case Enum.find(transports, &handles?(&1, address)) do
          nil -> {:error, "#{inspect(address)} is not an agent address: #{shapes(transports)}"}
          module -> {:ok, module}
        end
    end
  end

  # `handles?/1` is optional, and a binding without it is passed over rather
  # than asked — it is reachable by name, and nothing else.
  defp handles?(module, address) do
    Code.ensure_loaded?(module) and function_exported?(module, :handles?, 1) and
      module.handles?(address)
  end

  defp shapes([Distribution, HTTP]), do: "a node like :\"agent@host\", or a URL beginning http"
  defp shapes(transports), do: "none of #{inspect(transports)} handles it"
end
