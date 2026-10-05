defmodule LemieuxTest.A2AAgent do
  @moduledoc """
  Stands a whole lemieux agent up, for another node to talk to.

  Compiled rather than defined in a test file, and that is the entire reason
  it exists here. `Lemieux.A2A`'s tests run a second BEAM node and ask it
  questions; a module defined in a `.exs` has no object code, so the far node
  cannot resolve it and anonymous functions closed over the test module arrive
  as `:undef`.

  So the far node is only ever asked to call functions in *this* module, and
  the scripts a test wants are named rather than passed as closures.
  """

  alias Lemieux.A2A.Server
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool

  @typedoc """
  What the agent should answer with, named rather than given as a function.

  A function would have to cross the node boundary, and one closed over a
  test module cannot.
  """
  @type script :: {:says, String.t()} | :report_tools | :echo_prompt | :asks_then_answers

  @doc """
  Starts a runtime and an `Lemieux.A2A.Server` on this node.

  Everything is started inside a process that then waits forever, because
  every caller here arrives over `:erpc` and an `:erpc` call runs in a
  process that exits the moment it returns — taking every `start_link` with
  it. The supervision tree has to outlive the call that asked for it.
  """
  @spec start(tmp_dir :: Path.t(), script :: script(), opts :: keyword()) ::
          :ok | {:error, term()}
  def start(tmp_dir, script, opts \\ []) do
    parent = self()

    spawn(fn ->
      result =
        with {:ok, _supervisor} <- Lemieux.Supervisor.start_link(name: Lemieux.Supervisor),
             {:ok, _server} <- Server.start_link(options(tmp_dir, script, opts)) do
          :ok
        end

      send(parent, {:started, result})

      receive do: (:stop -> :ok)
    end)

    receive do
      {:started, :ok} -> :ok
      {:started, other} -> {:error, other}
    after
      15_000 -> {:error, :timeout}
    end
  end

  # `ask_user` is not in the default set, so an agent that should be able to
  # ask its caller a question has to be given it. See `Lemieux.A2A.Server` on
  # why a remote task keeps it when everything else that writes is stripped.
  defp options(tmp_dir, :asks_then_answers = script, opts) do
    options(tmp_dir, script, opts, [Lemieux.Tools.Read, Lemieux.Tools.AskUser])
  end

  defp options(tmp_dir, script, opts), do: options(tmp_dir, script, opts, nil)

  defp options(tmp_dir, script, opts, tools) do
    [
      supervisor: Lemieux.Supervisor,
      provider: Scripted.new(turns(script)),
      store: JSONL.new(tmp_dir),
      model: "test:model",
      cwd: tmp_dir,
      name: "the backend"
    ]
    |> then(fn base -> if tools, do: Keyword.put(base, :tools, tools), else: base end)
    |> Keyword.merge(opts)
  end

  # Built here, on the node that will run them, so no function crosses.
  defp turns({:says, text}), do: [[{:text_delta, text}, {:done, :stop}]]

  defp turns(:report_tools) do
    [
      fn request ->
        [{:text_delta, Enum.map_join(request.tools, ",", &Tool.name/1)}, {:done, :stop}]
      end
    ]
  end

  # Asks the caller something, and answers once it has been told. The tool is
  # `ask_user`, which is how a session asks anybody anything — see
  # `Lemieux.A2A.Server` on why that becomes `input_required` rather than an
  # ending.
  defp turns(:asks_then_answers) do
    [
      [
        {:tool_call,
         %{
           id: "call-1",
           name: "ask_user",
           arguments: %{
             "question" => "which environment?",
             "options" => [
               %{"label" => "staging"},
               %{"label" => "production"}
             ]
           }
         }},
        {:done, :tool_calls}
      ],
      fn request ->
        answer = request.entries |> List.last() |> Map.fetch!(:payload) |> Map.fetch!("output")

        [{:text_delta, "in #{answer}, it is fine"}, {:done, :stop}]
      end
    ]
  end

  defp turns(:echo_prompt) do
    [
      fn request ->
        text = request.entries |> List.last() |> Map.fetch!(:payload) |> Map.fetch!("text")

        [{:text_delta, text}, {:done, :stop}]
      end
    ]
  end

  @doc """
  Starts a lemieux runtime and nothing else, so the node is running the
  library but is not answering to other agents.
  """
  @spec start_silent() :: :ok
  def start_silent do
    parent = self()

    spawn(fn ->
      {:ok, _supervisor} = Lemieux.Supervisor.start_link(name: Lemieux.Supervisor)
      send(parent, :started)

      receive do: (:stop -> :ok)
    end)

    receive do
      :started -> :ok
    after
      15_000 -> :ok
    end
  end
end
