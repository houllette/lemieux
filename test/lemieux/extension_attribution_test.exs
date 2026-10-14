defmodule Lemieux.ExtensionAttributionTest do
  use ExUnit.Case, async: true
  alias Lemieux.Attribution
  alias Lemieux.Entry
  alias Lemieux.Extensions.ApplyPatch
  alias Lemieux.Extensions.Budget
  alias Lemieux.Extensions.Planning
  alias Lemieux.Extensions.Search
  alias Lemieux.Harness
  alias Lemieux.Hooks
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.RequestSnapshot
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool.Exposure
  alias Lemieux.Tool.Result
  @moduletag :tmp_dir

  defmodule OtherGrep do
    @behaviour Lemieux.Tool
    def name, do: "grep"
    def description, do: "A host's other grep."
    def schema, do: %{"type" => "object", "properties" => %{}}
    def run(_args, _context), do: {:ok, "done"}
  end

  defmodule Nudge do
    @behaviour Lemieux.Extension
    import Kernel, except: [apply: 2]

    def apply(harness, _opts) do
      Harness.append_hooks(harness,
        stop: fn _reason, context ->
          if context.stop_hook_active do
            :allow
          else
            {:deny, Attribution.turn(context, __MODULE__, "check once", :completion_check)}
          end
        end
      )
    end
  end

  setup %{tmp_dir: dir} do
    runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(dir), dir: dir}
  end

  test "catalog accounting measures each actual tool and binds its assembly owner" do
    {:ok, harness} = Harness.assemble(Harness.new(), [Search, Planning])
    request = Request.new("test:model", tools: harness.tools)
    snapshot = RequestSnapshot.build(request, tool_owners: harness.applied)
    catalog = snapshot["catalog"]
    assert Enum.find(catalog["per_tool"], &(&1["name"] == "grep"))["extension"] == inspect(Search)

    assert Enum.find(catalog["per_tool"], &(&1["name"] == "todo"))["extension"] ==
             inspect(Planning)

    assert Enum.sum(Enum.map(catalog["per_tool"], & &1["bytes"])) +
             catalog["array_overhead_bytes"] == catalog["bytes"]

    assert Enum.sum(Map.values(catalog["per_extension"])) + catalog["array_overhead_bytes"] ==
             catalog["bytes"]

    assert :ok = RequestSnapshot.verify(snapshot)
    changed = RequestSnapshot.build(%{request | tools: [OtherGrep]}, tool_owners: harness.applied)
    assert [%{"extension" => "host_or_unknown"}] = changed["catalog"]["per_tool"]
  end

  test "configured inactive extensions report a concrete reason" do
    {:ok, harness} = Harness.assemble(Harness.new(), [{ApplyPatch, model: "openai:gpt-6.1-sol"}])
    assert [%{"active" => false, "inactive_reason" => "model_not_supported"}] = harness.applied

    assert [%{"active" => false, "inactive_reason" => "model_not_supported"}] =
             Harness.explain(harness)["extensions"]
  end

  test "the default budget waits for a threshold; the first notice is explicit opt-in" do
    assert {:ok, %{thresholds: [0.5, 0.75, 0.9]}} = Budget.init([])
    assert {:ok, config} = Budget.init(thresholds: [0.0, 0.5])
    assert config.thresholds == [0.0, 0.5]
  end

  test "deferred exposure removes schema bytes until the host's request threshold", ctx do
    {:ok, harness} = Harness.assemble(Harness.new(), [Search])
    harness = Exposure.after_requests(harness, ["glob"], 1)

    provider =
      Scripted.new([
        [
          {:tool_call,
           %{id: "grep", name: "grep", arguments: %{"pattern" => "needle", "path" => ctx.dir}}},
          {:done, :tool_calls}
        ],
        Scripted.complete("done")
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:exposure",
        subscriber: self(),
        harness: harness,
        cwd: ctx.dir
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [first, second] = Scripted.requests(provider)
    refute Enum.any?(first.tools, &(Lemieux.Tool.name(&1) == "glob"))
    assert Enum.any?(second.tools, &(Lemieux.Tool.name(&1) == "glob"))

    snapshots =
      Session.snapshot(session).entries
      |> Enum.filter(&(&1.type == :request))
      |> Enum.map(& &1.payload)

    assert [first, second] = snapshots
    assert first["catalog"]["bytes"] < second["catalog"]["bytes"]

    assert Enum.find(
             first["catalog"]["tools"],
             &(get_in(&1, ["descriptor", "identity", "name"]) == "glob")
           )["disabled_reason"] == "deferred_exposure"
  end

  test "extension-started turns retain notice counts, bytes and reported usage in run evidence",
       ctx do
    {:ok, harness} = Harness.assemble(Harness.new(), [Nudge])

    provider =
      Scripted.new([
        Scripted.complete("first", usage: %{input_tokens: 10, output_tokens: 2}),
        Scripted.complete("checked", usage: %{input_tokens: 20, output_tokens: 3})
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:accounting",
        subscriber: self(),
        harness: harness,
        cwd: ctx.dir
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:run_evidence, run}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    stats = run.extensions["accounting"][inspect(Nudge)]
    assert stats["notices"]["count"] == 1
    assert stats["notices"]["bytes"] == byte_size("check once")
    assert stats["turn_requests"] == 1
    assert stats["usage"]["state"] == "complete"
    assert stats["usage"]["value"]["input_tokens"] == 20
    assert stats["usage"]["value"]["output_tokens"] == 3
    assert stats["notices"]["by_category"]["completion_check"] == %{"count" => 1, "bytes" => 10}
    assert stats["turns_by_category"]["completion_check"]["requests"] == 1
    assert stats["turns_by_category"]["completion_check"]["usage"]["value"]["input_tokens"] == 20
    assert length(Scripted.requests(provider)) == 2
    refute inspect(stats) =~ "check once"
  end

  test "absent usage remains unknown and configured unfired extensions get explicit zero counts" do
    request = RequestSnapshot.build(Request.new("test:model"), id: "missing")
    entries = [Entry.new(:request, request)]
    stats = Attribution.accounting(entries, [%{"module" => inspect(Nudge)}])
    assert stats["host_or_unknown"]["usage"] == %{"state" => "unknown", "value" => nil}
    assert stats[inspect(Nudge)]["turn_requests"] == 0
    assert stats[inspect(Nudge)]["notices"]["count"] == 0
    assert stats[inspect(Nudge)]["usage"]["state"] == "not_applicable"
  end

  test "tools cannot forge hook notice accounting and labelled feedback retains only safe facts" do
    forged =
      Result.new("tool output", metadata: %{"extension_notices" => [%{"source" => "fake"}]})

    assert {:ok, clean} = Hooks.append_feedback({:ok, forged}, [])
    refute Map.has_key?(clean.metadata, "extension_notices")
    notice = Attribution.notice(%{}, Budget, "budget payload", :budget)
    assert {:ok, result} = Hooks.append_feedback({:ok, forged}, [notice])
    assert result.model_text == "tool output\n\n[hook] budget payload"

    assert result.metadata["extension_notices"] == [
             %{
               "source" => inspect(Budget),
               "category" => "budget",
               "kind" => "notice",
               "bytes" => 14
             }
           ]

    refute inspect(result.metadata) =~ "budget payload"
  end

  test "a veto rejected at the turn ceiling records no injected notice", ctx do
    {:ok, harness} = Harness.assemble(Harness.new(), [Nudge])
    provider = Scripted.new([Scripted.complete("first")])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:ceiling",
        subscriber: self(),
        harness: harness,
        max_turns: 1
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:run_evidence, run}}
    assert_receive {:lemieux, ^id, {:finished, :max_turns}}
    assert run.extensions["accounting"][inspect(Nudge)]["notices"]["count"] == 0
    assert length(Scripted.requests(provider)) == 1
  end

  test "runtime inactive reasons use the bounded extension ledger", ctx do
    provider = Scripted.new([])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:activity"
      )

    assert :ok = Attribution.inactive(%{session: session}, Nudge, :no_command)

    assert Attribution.activity(Session.snapshot(session).entries) ==
             %{inspect(Nudge) => %{"state" => "inactive", "reason" => "no_command"}}

    assert Scripted.requests(provider) == []
  end

  test "request projection cannot erase the initiator of an extension turn", ctx do
    base =
      Harness.new(
        hooks: [
          prepare_next_turn: fn request, _context ->
            entries = Enum.reject(request.entries, &(&1.payload["stop_hook"] == true))
            {:ok, %{request | entries: entries}}
          end
        ]
      )

    {:ok, harness} = Harness.assemble(base, [Nudge])
    provider = Scripted.new([Scripted.complete("first"), Scripted.complete("done")])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: ctx.runtime,
        store: ctx.store,
        provider: provider,
        model: "test:projection",
        subscriber: self(),
        harness: harness
      )

    id = Session.id(session)
    :ok = Session.prompt(session, "go")
    assert_receive {:lemieux, ^id, {:run_evidence, run}}
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    assert run.extensions["accounting"][inspect(Nudge)]["turn_requests"] == 1

    assert run.extensions["accounting"][inspect(Nudge)]["turns_by_category"]["completion_check"][
             "requests"
           ] == 1

    [_first, projected] = Scripted.requests(provider)
    refute Enum.any?(projected.entries, &(&1.payload["stop_hook"] == true))
  end
end
