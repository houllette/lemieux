defmodule Lemieux.Eval.Attach do
  @moduledoc """
  Reaching a BEAM node somebody else is running.

  `Lemieux.Eval.Sandbox` gives the model a node of its own, which is the safe
  place to compute things. This is the other direction: the model evaluates
  **inside an application that is already running**, so it can look at live
  processes, the contents of ETS, and whatever an `Ecto.Repo` says right now.

  It is the one thing a harness that wraps a vendor CLI structurally cannot
  do, and the strongest argument for a coding agent that lives on the BEAM at
  all. The idea, and the mechanism, are
  [beamcore](https://github.com/beamcore/agent)'s.

  ## Nothing is added to the target

  The application being attached to has never heard of lemieux and does not
  depend on it. One module — `Lemieux.Eval.Runner`, and only that module —
  is sent over as compiled bytes and loaded with `:code.load_binary/3`, which
  is why that module is written to reference nothing else in this library.

  So attaching to your own Phoenix app needs no `mix.exs` change, no restart
  and no dependency. It needs the app to have been started as a **named**
  node, because an unnamed one is not reachable at all:

      iex --sname myapp -S mix phx.server

  ## This is the trusted-user end of the tool

  Evaluating inside a live application is strictly more dangerous than
  evaluating on a node of our own, and `Lemieux.Eval.Sandbox` explains why
  that separate node exists. Code that runs here runs *as* the application:
  it can read its secrets, mutate its state, crash its supervisors, and write
  to its database. The isolation the sandbox buys is given up on purpose, in
  exchange for being able to see the thing you are actually debugging.

  So attaching is always something a person asks for by name. It never
  happens because a node was discovered, and the model cannot ask for it —
  `Lemieux.Tools.Eval` has no argument that reaches this.

  ## Cookies

  Two nodes may only speak if they share a cookie. On one machine and one
  user, both sides read `~/.erlang.cookie` and it simply works. Across
  machines it must be arranged, and the failure looks like a node that will
  not connect rather than one that refuses — which is why `attach/1` says so
  in as many words rather than reporting `false`.
  """

  alias Lemieux.Eval.Runner

  @epmd_timeout 1_000

  @doc """
  The named nodes running on this machine.

  Read from epmd, which is the only thing that knows. Our own node is left
  out, as are the evaluation nodes lemieux started for itself — offering
  somebody a list containing the sandbox they are already using would be
  offering them a loop.
  """
  @spec candidates() :: [atom()]
  def candidates do
    case epmd_names() do
      {:ok, names} -> Enum.flat_map(names, &named/1)
      {:error, _reason} -> []
    end
  end

  # `:erl_epmd.names/0` resolves the machine's default hostname, which need not be
  # the address distribution is using, and that lookup can block for the TCP
  # connect timeout when local DNS is unhealthy. Ask the host encoded in our own
  # node name and keep discovery best-effort: an unavailable epmd means there are
  # simply no candidates.
  defp epmd_names do
    task = Task.async(fn -> :erl_epmd.names(String.to_charlist(host())) end)

    case Task.yield(task, @epmd_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _timeout_or_exit -> {:error, :unavailable}
    end
  end

  defp named({name, _port}) do
    name = List.to_string(name)

    if name == mine() or String.starts_with?(name, "lmx-eval-"),
      do: [],
      else: [String.to_atom(name <> "@" <> host())]
  end

  defp mine do
    case node() do
      :nonode@nohost -> ""
      name -> name |> Atom.to_string() |> String.split("@", parts: 2) |> hd()
    end
  end

  # Our own node's host when there is one, and only then this machine's name.
  # They are not the same string: a node reached as `@127.0.0.1` has peers
  # named the same way, and completing them with the system hostname instead
  # produces names that look right and resolve to nothing.
  defp host do
    case node() do
      :nonode@nohost ->
        {:ok, host} = :inet.gethostname()

        List.to_string(host)

      name ->
        name |> Atom.to_string() |> String.split("@", parts: 2) |> List.last()
    end
  end

  @doc """
  What `/attach` says when it was given no name.

  Here rather than in either front end, because both say it and a list of
  running nodes phrased two ways is a list that drifts.
  """
  @spec offer() :: String.t()
  def offer do
    case candidates() do
      [] ->
        "nothing named is running on this machine. An application is only " <>
          "reachable if it was started as a node: iex --sname myapp -S mix phx.server"

      nodes ->
        "running here:\n" <>
          Enum.map_join(nodes, "\n", &"  #{&1}") <>
          "\n\n/attach NAME to evaluate inside one of them."
    end
  end

  @doc """
  What `/attach NAME` says about how it went.
  """
  @spec said({:ok, node()} | {:error, String.t()}) :: String.t()
  def said({:ok, node}),
    do: "attached to #{node} — the elixir tool now runs there. /detach to stop."

  def said({:error, reason}), do: reason

  @doc """
  Connects to `target` and puts `Lemieux.Eval.Runner` on it.

  `target` may be a bare name (`"myapp"`), which is completed with this
  machine's hostname, or a full one (`"myapp@somewhere"`).

  Returns the node it reached, so a caller has something to show and
  something to route to.
  """
  @spec attach(target :: String.t() | atom()) :: {:ok, node()} | {:error, String.t()}
  def attach(target) do
    node = full(target)

    with :ok <- distributed(node),
         :ok <- connect(node) do
      inject(node)
    end
  end

  defp full(target) when is_atom(target), do: target

  defp full(target) do
    if String.contains?(target, "@"),
      do: String.to_atom(target),
      else: String.to_atom(target <> "@" <> host())
  end

  # Distribution is started on demand rather than at boot, because a CLI that
  # opened a distribution port on every run would be taking a decision nobody asked
  # it to take. The naming mode has to match the target's: a node started with
  # `--sname` cannot speak to one started with `--name`, and the symptom is a
  # connection that fails with no reason given, so it is read off the target's own
  # shape rather than guessed.
  defp distributed(target) do
    case node() do
      :nonode@nohost -> start(mode(target))
      _already -> :ok
    end
  end

  defp mode(target) do
    [_name, host] = target |> Atom.to_string() |> String.split("@", parts: 2)

    if String.contains?(host, "."), do: :longnames, else: :shortnames
  end

  defp start(mode) do
    name = :"lmx-#{System.unique_integer([:positive])}"

    case Node.start(name, name_domain: mode) do
      {:ok, _pid} ->
        :ok

      {:error, reason} ->
        {:error,
         "could not start distribution as #{name}: #{inspect(reason)}. " <>
           "Attaching needs epmd, which is running whenever a named node is."}
    end
  end

  defp connect(node) do
    if Node.connect(node) == true do
      :ok
    else
      {:error,
       "could not reach #{node}. It has to be running and named — " <>
         "`iex --sname #{node |> Atom.to_string() |> String.split("@", parts: 2) |> hd()} -S mix` — " <>
         "and on another machine it also has to share this one's ~/.erlang.cookie."}
    end
  end

  # The whole of what is added to somebody else's application.
  defp inject(node) do
    with {:ok, module, binary, file} <- object_code(),
         {:module, ^module} <- :erpc.call(node, :code, :load_binary, [module, file, binary]) do
      {:ok, node}
    else
      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, "could not put the runner on #{node}: #{inspect(other)}"}
    end
  catch
    # An `:erpc` to a node that went away between connecting and calling
    # raises rather than returning, and "it disappeared" is a better thing to
    # read than a stacktrace through `:erpc`.
    kind, reason ->
      {:error, "#{node} stopped answering while attaching: #{inspect({kind, reason})}"}
  end

  defp object_code do
    case :code.get_object_code(Runner) do
      {module, binary, file} ->
        {:ok, module, binary, file}

      :error ->
        {:error,
         "cannot read this build's own compiled runner, so there is nothing to " <>
           "send. Attaching needs a source checkout or a standard OTP release " <>
           "with readable object code."}
    end
  end
end
