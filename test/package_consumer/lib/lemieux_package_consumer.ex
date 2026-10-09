defmodule LemieuxPackageConsumer do
  @moduledoc false

  @spec version() :: String.t()
  def version, do: Lemieux.version()

  alias Lemieux.Extensions.A2UI
  alias Lemieux.Extensions.A2UI.Diagram
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool
  alias LemieuxPackageConsumer.Audit
  alias LemieuxPackageConsumer.Environment

  @doc "Runs one phase in a fresh VM using only the packaged public library."
  @spec verify(phase :: String.t(), directory :: Path.t()) :: :ok
  def verify(phase, directory) when phase in ["seed", "resume", "tighten"] do
    false = Code.ensure_loaded?(ExRatatui)
    false = Code.ensure_loaded?(Ascii)
    false = Diagram.available?()

    :error =
      Diagram.prepare(%{
        "component" => "MermaidDiagram",
        "source" => "flowchart LR\nA --> B"
      })

    [] = A2UI.apply(Harness.new(tools: []), []).tools
    true = Application.spec(:lemieux, :mod) in [nil, []]
    {:ok, supervisor} = Lemieux.Supervisor.start_link(name: __MODULE__.Supervisor)
    store = JSONL.new(directory)
    File.mkdir_p!(directory)
    {:ok, harness} = Harness.assemble(Harness.new(tools: []), [Audit])

    script =
      if phase == "tighten",
        do: [Scripted.complete("done")],
        else: [
          Scripted.tool_call("query-#{phase}", "scoped_query", %{}),
          Scripted.complete("done")
        ]

    script =
      if phase == "resume", do: script ++ [Scripted.complete("Packaged summary")], else: script

    provider = Scripted.new(script)

    options = [
      supervisor: __MODULE__.Supervisor,
      provider: provider,
      store: store,
      subscriber: self(),
      model: "test:model",
      harness: harness,
      # Request ceilings include historical requests on resume.
      max_requests: %{"seed" => 2, "resume" => 5, "tighten" => 6}[phase],
      tools: [],
      environment: Environment,
      cwd: "/",
      keep: 0.5,
      compact_at: nil
    ]

    options = if phase == "tighten", do: Keyword.put(options, :host_tools, []), else: options
    {:ok, session} = open(phase, directory, options)
    id = Session.id(session)
    File.write!(Path.join(directory, "session-id"), id)
    :ok = Session.prompt(session, "Report the scoped count")
    :ok = finished(id, :stop)
    requests = Scripted.requests(provider)
    expected = if phase == "tighten", do: [], else: ["scoped_query"]
    true = Enum.all?(requests, &(Enum.map(&1.tools, fn tool -> Tool.name(tool) end) == expected))
    {:ok, entries} = Store.read(store, id)

    if phase != "tighten" do
      true =
        Enum.any?(
          entries,
          &(&1.type == :tool_result and &1.payload["output"] == "rows: 2 [audited]")
        )

      2 = length(requests)
    end

    if phase == "resume" do
      {:ok, _} = Session.compact(session)
      summary_request = provider |> Scripted.requests() |> List.last()
      true = summary_request.system =~ "Preserve unanswered analysis questions."
      {:ok, compacted} = Store.read(store, id)
      ^entries = Enum.take(compacted, length(entries))
    end

    if phase == "tighten", do: true = hd(requests).system =~ "Packaged summary"

    GenServer.stop(session)
    :ok = verify_host_limit(harness, store)

    [] =
      DynamicSupervisor.which_children(
        Lemieux.Supervisor.session_supervisor(__MODULE__.Supervisor)
      )

    Supervisor.stop(supervisor)
    IO.puts("verified packaged #{phase}: #{length(entries)} entries")
    :ok
  end

  defp open("seed", _directory, options), do: Lemieux.start_session(options)

  defp open(_phase, directory, options),
    do:
      Lemieux.resume_session([resume: File.read!(Path.join(directory, "session-id"))] ++ options)

  defp verify_host_limit(harness, store) do
    provider =
      Scripted.new([
        Scripted.tool_call("denied", "scoped_query", %{}),
        Scripted.complete("unreachable")
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: __MODULE__.Supervisor,
        provider: provider,
        store: store,
        model: "test:model",
        subscriber: self(),
        harness: harness,
        tools: [],
        max_requests: 1,
        environment: Environment,
        hooks: [before_tool_call: fn _, _ -> {:deny, "host policy"} end]
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "query")

    receive do
      {:lemieux, ^id, {:finished, {:budget, %{kind: :requests}}}} -> :ok
    after
      5_000 -> raise "host request limit did not terminate the session"
    end

    1 = length(Scripted.requests(provider))
    {:ok, entries} = Store.read(store, id)

    true =
      Enum.any?(entries, &(&1.type == :tool_result and &1.payload["output"] =~ "host policy"))

    GenServer.stop(session)
    :ok
  end

  defp finished(id, reason) do
    receive do
      {:lemieux, ^id, {:finished, ^reason}} -> :ok
      {:lemieux, ^id, {:finished, other}} -> raise "unexpected finish: #{inspect(other)}"
    after
      5_000 -> raise "packaged consumer did not finish"
    end
  end
end
