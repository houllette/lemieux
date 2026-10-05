defmodule Lemieux.A2A.Transport.Distribution do
  @moduledoc """
  Peer operations in a trusted BEAM runtime domain. Erlang distribution uses
  TCP ports and normally epmd. Shared cookies authorize arbitrary VM RPC;
  this binding is not a sandbox or authentication boundary for hostile peers.
  Multiple server instances are selected with the trusted host's `:server`
  option. An RPC timeout detaches from work; the server deadline still applies.
  """

  @behaviour Lemieux.A2A.Transport

  alias Lemieux.A2A.Server

  # Any atom: a node name is one, and nothing else addresses an agent as one.
  @impl Lemieux.A2A.Transport
  def handles?(address), do: is_atom(address)

  # Distribution is not lossless: a node can be up, reachable, and then gone
  # between one call and the next. Every call here catches that rather than
  # letting an `:erpc` exit travel up through a caller that was asking a
  # question and has no idea what a `:badrpc` is.
  @impl Lemieux.A2A.Transport
  def send_message(node, message, opts \\ []) do
    remote(
      node,
      :ask,
      [message, Keyword.drop(opts, [:transport, :transports])],
      Keyword.get(opts, :timeout, 190_000)
    )
  end

  @impl Lemieux.A2A.Transport
  def get_task(node, task_id), do: get_task(node, task_id, [])
  @impl Lemieux.A2A.Transport
  def get_task(node, task_id, opts),
    do: remote(node, :get_task, [task_id, opts], Keyword.get(opts, :timeout, 30_000))

  @impl Lemieux.A2A.Transport
  def cancel_task(node, task_id), do: cancel_task(node, task_id, [])
  @impl Lemieux.A2A.Transport
  def cancel_task(node, task_id, opts),
    do: remote(node, :cancel_task, [task_id, opts], Keyword.get(opts, :timeout, 30_000))

  @impl Lemieux.A2A.Transport
  def card(node), do: card(node, [])
  @impl Lemieux.A2A.Transport
  def card(node, opts), do: remote(node, :card, [opts], Keyword.get(opts, :timeout, 30_000))
  @impl Lemieux.A2A.Transport
  def list_tasks(node, params, opts),
    do: remote(node, :list_tasks, [params, opts], Keyword.get(opts, :timeout, 30_000))

  @impl Lemieux.A2A.Transport
  def subscribe(node, id, opts),
    do:
      remote(
        node,
        :subscribe,
        [id, Keyword.get(opts, :stream, self()), opts],
        Keyword.get(opts, :timeout, 30_000)
      )

  defp remote(node, function, args, timeout) do
    :erpc.call(node, Server, function, args, timeout)
  catch
    :error, {:erpc, :noconnection} ->
      {:error,
       "cannot reach #{node}. It has to be running, named, and sharing this " <>
         "machine's ~/.erlang.cookie."}

    :error, {:erpc, :timeout} ->
      {:error, "#{node} did not answer in time"}

    # An agent that is running lemieux but never started a server answers with
    # its own sentence; this is for a node that is not running lemieux at all,
    # where the module simply is not there.
    :error, {:exception, :undef, _stack} ->
      {:error, "#{node} is a BEAM node, but it is not an lmx agent"}

    kind, reason ->
      {:error, "#{node} failed to answer: #{inspect({kind, reason})}"}
  end
end
