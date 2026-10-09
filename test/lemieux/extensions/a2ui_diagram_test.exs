defmodule Lemieux.Extensions.A2UIDiagramTest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions.A2UI
  alias Lemieux.Extensions.A2UI.{Diagram, DiagramPreview}
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool

  defp mermaid(source), do: %{"component" => "MermaidDiagram", "source" => source}

  test "Mermaid and native graphs compile to bounded variants with complete relationship summaries" do
    inputs = [
      mermaid("flowchart LR\nA[Request] -->|send| B(Worker)"),
      %{
        "component" => "Flowchart",
        "direction" => "LR",
        "nodes" => [%{"id" => "a", "label" => "Request"}, %{"id" => "b", "label" => "Worker"}],
        "edges" => [%{"from" => "a", "to" => "b", "label" => "send"}]
      },
      %{
        "component" => "SequenceDiagram",
        "participants" => [%{"id" => "a"}, %{"id" => "b"}],
        "events" => [%{"from" => "a", "to" => "b", "label" => "request"}]
      },
      %{
        "component" => "C4Diagram",
        "level" => "container",
        "elements" => [%{"id" => "api", "technology" => "Elixir", "boundary" => "app"}],
        "relationships" => [],
        "boundaries" => [%{"id" => "app", "label" => "Application"}]
      }
    ]

    for input <- inputs do
      assert {:ok, prepared} = Diagram.prepare(input)
      assert prepared.variants != []
      assert Enum.all?(prepared.variants, &(&1.cols <= 200 and &1.rows <= 100))
      assert prepared.cells <= 60_000
    end

    {:ok, prepared} = Diagram.prepare(hd(inputs))
    assert prepared.summary =~ "Request -> Worker: send"
    assert Enum.any?(prepared.variants, &(&1.cols < 60))
  end

  test "syntax, unsupported styles, invalid references, wide labels and record budgets fail explicitly" do
    for input <- [
          mermaid("flowchart LR\nclick A callback"),
          mermaid("flowchart LR\nA[hello]\nstyle A color:#ffffff"),
          mermaid("flowchart LR\nA[😀]"),
          mermaid("flowchart LR\n" <> Enum.map_join(1..17, "\n", &"n#{&1}")),
          mermaid(String.duplicate("a", 8193)),
          %{
            "component" => "Flowchart",
            "nodes" => [%{"id" => "a"}],
            "edges" => [%{"from" => "a", "to" => "missing"}]
          },
          %{
            "component" => "Flowchart",
            "nodes" => [%{"id" => "a", "module" => "File"}],
            "edges" => []
          }
        ],
        do: assert(match?({:error, _}, Diagram.prepare(input)))

    assert {:error, message} = Diagram.prepare(mermaid("flowchart LR\nclick A callback"))
    assert message =~ "line 2"
  end

  test "nested sequence events preserve branches, notes and activations in text fallback" do
    source =
      "sequenceDiagram\nparticipant A as API\nparticipant B as Worker\nloop retry\nA->>+B: work\nalt valid\nB-->>A: accepted\nelse invalid\nB-->>A: rejected\nend\ndeactivate B\nend\nNote over A,B: finished"

    assert {:ok, prepared} = Diagram.prepare(mermaid(source))

    for text <- [
          "loop: retry",
          "alt: valid",
          "branch: invalid",
          "API -> Worker: work",
          "accepted",
          "rejected",
          "note",
          "finished"
        ],
        do: assert(prepared.summary =~ text)
  end

  test "the advertised preview tool reports fit and validation without effects" do
    harness = A2UI.apply(Harness.new(), [])
    assert Enum.any?(harness.tools, &(Tool.name(&1) == "diagram_preview"))
    assert DiagramPreview.read_only?()
    assert DiagramPreview.parallel_safe?()

    assert {:ok, result} =
             DiagramPreview.run(
               %{
                 "diagram" => mermaid("flowchart LR\nA[Request] -->|send| B[Worker]"),
                 "width" => 12
               },
               %{}
             )

    assert result.structured_content["valid"]
    refute result.structured_content["fits"]
    assert result.model_text =~ "Request -> Worker: send"
    assert {:error, error} = DiagramPreview.run(%{"diagram" => mermaid("pie\nwrong")}, %{})
    assert error =~ "header"

    assert {:ok, wide} =
             DiagramPreview.run(
               %{
                 "diagram" => mermaid("flowchart LR\nA[Request] -->|send| B[Worker]"),
                 "width" => 80
               },
               %{}
             )

    assert wide.structured_content["preview"] =~ "─"
    assert wide.model_text =~ wide.structured_content["preview"]
  end

  test "catalog and preview schemas accept shipped native forms and reject unsupported input" do
    catalog =
      Path.join(:code.priv_dir(:lemieux), "a2ui/catalog.json") |> File.read!() |> JSON.decode!()

    inputs = [
      mermaid(~s|C4Context\nPerson(user, "User")\nSystem(api, "API")\nRel(user, api, "uses")|),
      %{
        "component" => "Flowchart",
        "nodes" => [%{"id" => "a", "shape" => "diamond"}],
        "edges" => []
      },
      %{
        "component" => "SequenceDiagram",
        "participants" => [%{"id" => "a"}],
        "events" => [
          %{
            "kind" => "loop",
            "label" => "retry",
            "events" => [%{"from" => "a", "to" => "a", "label" => "work"}]
          }
        ]
      },
      %{
        "component" => "C4Diagram",
        "level" => "component",
        "elements" => [%{"id" => "a", "kind" => "database"}],
        "relationships" => []
      }
    ]

    preview = JSV.build!(DiagramPreview.schema())

    for input <- inputs do
      input = Map.put(input, "id", "root")
      validator = JSV.build!(catalog["components"][input["component"]])
      assert {:ok, ^input} = JSV.validate(input, validator)
      assert {:ok, _} = JSV.validate(%{"diagram" => input, "width" => 80}, preview)
      assert {:ok, _} = Diagram.prepare(input)
      assert {:ok, _} = JSV.validate(Map.put(input, "width", %{"path" => "/width"}), validator)
      assert {:error, _} = JSV.validate(Map.put(input, "x", 10), validator)
      assert {:error, _} = Diagram.prepare(Map.put(input, "width", 201))
    end

    bad = %{
      "component" => "Flowchart",
      "nodes" => [%{"id" => "a", "shape" => "hexagon"}],
      "edges" => []
    }

    assert {:error, _} = Diagram.prepare(bad)
    assert {:error, _} = DiagramPreview.run(%{"diagram" => bad}, %{})

    assert {:error, _} =
             Diagram.prepare(mermaid("flowchart TB\nA[" <> String.duplicate("a", 257) <> "]"))

    assert {:error, _} = Diagram.prepare(mermaid("flowchart TB\n" <> String.duplicate("a", 65)))
  end

  @tag :tmp_dir
  test "the agent loop can preview, read the result, then emit the unchanged visualization source",
       %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    node = mermaid("flowchart LR\nA[Request] -->|send| B[Worker]")
    answer = "```mermaid\n" <> node["source"] <> "\n```"

    provider =
      Scripted.new([
        Scripted.tool_call("preview", "diagram_preview", %{"diagram" => node, "width" => 80}),
        Scripted.complete(answer)
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        store: JSONL.new(dir),
        provider: provider,
        model: "test:diagram",
        cwd: dir,
        subscriber: self(),
        harness: A2UI.apply(Harness.new(tools: []), [])
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "Explain the request path")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [first, second] = Scripted.requests(provider)
    assert Enum.any?(first.tools, &(Tool.name(&1) == "diagram_preview"))
    result = Enum.find(second.entries, &(&1.type == :tool_result))
    assert result.payload["output"] =~ "Request -> Worker: send"

    assert Enum.any?(
             Session.snapshot(session).entries,
             &(&1.type == :assistant and
                 &1.payload["content"] == [%{"type" => "text", "text" => answer}])
           )

    GenServer.stop(session)
  end

  test "nested event budgets apply to native records and oversized geometry retains all relationships" do
    event = %{"from" => "a", "to" => "b", "label" => "request"}

    native = %{
      "component" => "SequenceDiagram",
      "participants" => [%{"id" => "a"}, %{"id" => "b"}],
      "events" => [event]
    }

    deep =
      Enum.reduce(1..5, event, fn _, child ->
        %{"kind" => "loop", "label" => "repeat", "events" => [child]}
      end)

    assert {:error, _} = Diagram.prepare(%{native | "events" => [deep]})

    group = %{
      "kind" => "alt",
      "events" => [],
      "branches" => List.duplicate(%{"label" => "branch", "events" => []}, 5)
    }

    assert {:error, _} = Diagram.prepare(%{native | "events" => [group]})

    groups =
      Enum.map(1..2, fn _ -> %{"kind" => "loop", "events" => List.duplicate(event, 24)} end)

    assert {:error, _} = Diagram.prepare(%{native | "events" => groups})
    assert {:ok, prepared} = Diagram.prepare(%{native | "events" => List.duplicate(event, 48)})
    assert prepared.variants == []
    assert length(String.split(prepared.summary, "request")) == 49
  end

  test "0.4 state and ER models and grouped flowcharts render from Mermaid and native JSON" do
    inputs = [
      mermaid("stateDiagram-v2\n[*] --> Idle\nIdle --> Working: start\nWorking --> [*]: done"),
      %{
        "component" => "StateDiagram",
        "direction" => "LR",
        "states" => [
          %{"id" => "start", "kind" => "initial"},
          %{"id" => "idle", "label" => "Idle"},
          %{"id" => "finish", "kind" => "final"}
        ],
        "transitions" => [
          %{"from" => "start", "to" => "idle"},
          %{"from" => "idle", "to" => "finish", "label" => "done"}
        ]
      },
      mermaid(
        "erDiagram\nCUSTOMER ||..o{ ORDER : places\nCUSTOMER {\ninteger id PK\nstring email UK \"Login address\"\n}\nORDER {\ninteger customer_id FK\n}"
      ),
      %{
        "component" => "ERDiagram",
        "direction" => "LR",
        "entities" => [
          %{
            "id" => "customer",
            "attributes" => [%{"name" => "id", "type" => "integer", "keys" => ["pk"]}]
          },
          %{"id" => "order", "attributes" => [%{"name" => "customer_id", "keys" => ["fk"]}]}
        ],
        "relationships" => [
          %{
            "from" => "customer",
            "to" => "order",
            "label" => "places",
            "from_cardinality" => "one",
            "to_cardinality" => "zero_or_more",
            "identifying" => false
          }
        ]
      },
      mermaid(
        "flowchart LR\nsubgraph app [Application]\ndirection TB\nA[API] --> B[Worker]\nend\napp --> C[User]"
      ),
      %{
        "component" => "Flowchart",
        "nodes" => [%{"id" => "a", "label" => "First\nSecond", "group" => "inner"}],
        "edges" => [%{"from" => "a", "to" => "outer"}],
        "groups" => [
          %{"id" => "outer", "label" => "Application"},
          %{"id" => "inner", "parent" => "outer", "direction" => "TB"}
        ]
      }
    ]

    for input <- inputs do
      assert {:ok, prepared} = Diagram.prepare(input)
      assert prepared.variants != []
      assert Enum.all?(prepared.variants, &(&1.cols <= 200 and &1.rows <= 100))
    end

    assert {:ok, er} = Diagram.prepare(Enum.at(inputs, 3))

    for expected <- ["integer id PK", "customer_id FK", "0..*", "non-identifying"],
        do: assert(er.summary =~ expected)

    assert {:ok, flow} = Diagram.prepare(List.last(inputs))

    for expected <- ["Application", "inner", "TB", "First", "Second"],
        do: assert(flow.summary =~ expected)
  end

  test "new groups, states and ER attributes retain explicit reference and size limits" do
    state = %{
      "component" => "StateDiagram",
      "states" => [%{"id" => "a", "kind" => "final"}, %{"id" => "b"}],
      "transitions" => [%{"from" => "a", "to" => "b"}]
    }

    assert {:error, _} = Diagram.prepare(state)

    flow = %{
      "component" => "Flowchart",
      "nodes" => [],
      "edges" => [],
      "groups" => [%{"id" => "empty", "label" => "Empty group"}]
    }

    assert {:ok, _} = Diagram.prepare(flow)

    assert {:error, _} =
             Diagram.prepare(%{flow | "groups" => Enum.map(1..7, &%{"id" => "g#{&1}"})})

    er = %{
      "component" => "ERDiagram",
      "entities" => [%{"id" => "a", "attributes" => Enum.map(1..17, &%{"name" => "field#{&1}"})}],
      "relationships" => []
    }

    assert {:error, _} = Diagram.prepare(er)

    assert {:error, _} =
             Diagram.prepare(%{
               er
               | "entities" => [
                   %{"id" => "a", "attributes" => [%{"name" => "id", "keys" => ["execute"]}]}
                 ]
             })
  end

  test "simple Mermaid emission and optional preview keep routine request context small" do
    instructions = A2UI.instructions()
    assert byte_size(instructions) < 4000
    assert instructions =~ "stateDiagram-v2"
    assert instructions =~ "erDiagram"
    refute instructions =~ "Before showing a diagram, use diagram_preview"
    assert byte_size(JSON.encode!(DiagramPreview.schema())) < 1800

    assert {:ok, result} =
             DiagramPreview.run(
               %{"source" => "stateDiagram-v2\n[*] --> Ready", "width" => 80},
               %{}
             )

    assert result.structured_content["family"] == "state"
  end

  test "new native catalog components validate their data and bounded layout controls" do
    catalog =
      Path.join(:code.priv_dir(:lemieux), "a2ui/catalog.json") |> File.read!() |> JSON.decode!()

    inputs = [
      %{
        "component" => "StateDiagram",
        "states" => [
          %{"id" => "work", "kind" => "composite"},
          %{"id" => "idle", "label" => "Idle\nReady", "parent" => "work"}
        ],
        "transitions" => []
      },
      %{
        "component" => "ERDiagram",
        "entities" => [
          %{
            "id" => "customer",
            "attributes" => [
              %{"name" => "id", "type" => "integer", "keys" => ["pk"], "comment" => "Identity"}
            ]
          }
        ],
        "relationships" => []
      },
      %{
        "component" => "Flowchart",
        "nodes" => [],
        "edges" => [],
        "groups" => [%{"id" => "g", "label" => "Group", "direction" => "LR"}]
      }
    ]

    for input <- inputs do
      input =
        Map.merge(input, %{"id" => "root", "width" => 80, "padding" => 1, "align" => "center"})

      schema = JSV.build!(catalog["components"][input["component"]])
      assert {:ok, ^input} = JSV.validate(input, schema)
      assert {:ok, _} = Diagram.prepare(input)
      assert {:error, _} = JSV.validate(Map.put(input, "action", %{"name" => "bash"}), schema)
      assert {:error, _} = Diagram.prepare(Map.put(input, "action", %{"name" => "bash"}))
    end

    assert {:error, _} =
             DiagramPreview.run(%{"source" => "flowchart TB\nA", "diagram" => hd(inputs)}, %{})
  end

  @tag :tmp_dir
  test "an agent can display the expanded families in its first answer without a preview turn", %{
    tmp_dir: dir
  } do
    runtime = Module.concat(__MODULE__, "Direct#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    answer = "```mermaid\nstateDiagram-v2\n[*] --> Ready\n```"
    provider = Scripted.new([Scripted.complete(answer)])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: runtime,
        store: JSONL.new(dir),
        provider: provider,
        model: "test:direct",
        cwd: dir,
        subscriber: self(),
        harness: A2UI.apply(Harness.new(tools: []), [])
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "Show the state")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert length(Scripted.requests(provider)) == 1

    assert Enum.any?(
             Session.snapshot(session).entries,
             &(&1.type == :assistant and
                 &1.payload["content"] == [%{"type" => "text", "text" => answer}])
           )

    refute Enum.any?(Session.snapshot(session).entries, &(&1.type == :tool_result))
    GenServer.stop(session)
  end
end
