defmodule Lemieux.Hooks.CompositionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Hooks.Command
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias LemieuxTest.Shell

  @moduletag :tmp_dir

  defmodule Marker do
    @moduledoc false
    @behaviour Lemieux.Tool

    @impl true
    def name, do: "marker"
    @impl true
    def description, do: "Records the path that actually executed."
    @impl true
    def schema, do: %{"type" => "object", "properties" => %{"path" => %{"type" => "string"}}}
    @impl true
    def run(%{"path" => path}, context) do
      File.write!(Path.join(context.cwd, "executed"), path)
      {:ok, "executed #{path}"}
    end
  end

  setup %{tmp_dir: dir} do
    runtime = :"hook_composition_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, marker: Path.join(dir, "executed")}
  end

  defp command(permission, rewritten \\ %{"path" => "hook.txt"}) do
    output = %{
      "hookSpecificOutput" => %{
        "permissionDecision" => permission,
        "permissionDecisionReason" => "review rewritten path",
        "updatedInput" => rewritten
      }
    }

    %Command{
      name: "gate",
      dialect: :claude,
      command: "printf '%s' " <> Shell.quoted(JSON.encode!(output))
    }
  end

  defp start(context, hooks) do
    provider =
      Scripted.new([
        Scripted.tool_call("c1", "marker", %{"path" => "original.txt"}),
        Scripted.complete("done")
      ])

    {:ok, session} =
      Lemieux.start_session(
        supervisor: context.runtime,
        provider: provider,
        model: "test:model",
        cwd: context.tmp_dir,
        store: JSONL.new(context.tmp_dir),
        subscriber: self(),
        tools: [Marker],
        hooks: hooks,
        approval_timeout: :timer.minutes(1)
      )

    id = Session.info(session).id
    assert :ok = Session.prompt(session, "go")
    {session, id, provider}
  end

  defp result(id, provider) do
    assert_receive {:lemieux, ^id, {:finished, :stop}}
    [_first, request] = Scripted.requests(provider)
    Enum.find(request.entries, &(&1.type == :tool_result)).payload
  end

  defp assert_execution(context, payload, expected) when is_binary(expected) do
    assert_receive {:following, "c1", %{"path" => ^expected}, nil}
    assert payload["arguments"] == %{"path" => expected}
    assert payload["output"] == "executed #{expected}"
    assert File.read!(context.marker) == expected
  end

  defp assert_execution(context, payload, nil) do
    assert payload["error"] == true
    assert payload["output"] =~ "declined"
    refute File.exists?(context.marker)
    refute_received {:following, _, _, _}
  end

  test "an explicit approval carries rewritten arguments and its identity to the next policy",
       context do
    parent = self()

    hooks = [
      before_tool_call: command("allow"),
      before_tool_call: fn call, ctx ->
        send(parent, {:following, call.arguments, Map.get(ctx, :approved_by)})
        {:rewrite, Map.put(call.arguments, "path", call.arguments["path"] <> ".next")}
      end
    ]

    {_session, id, provider} = start(context, hooks)

    payload = result(id, provider)
    assert_receive {:following, %{"path" => "hook.txt"}, "hook gate"}
    assert payload["arguments"] == %{"path" => "hook.txt.next"}
    assert payload["output"] == "executed hook.txt.next"
    assert File.read!(context.marker) == "hook.txt.next"
  end

  test "an explicit approval does not override a later denial", context do
    parent = self()

    hooks = [
      before_tool_call: command("allow"),
      before_tool_call: fn call, ctx ->
        send(parent, {:denied, call.arguments, ctx.approved_by})
        {:deny, "outside host policy"}
      end,
      before_tool_call: fn _call, _ctx ->
        send(parent, :unexpected_policy)
        :allow
      end
    ]

    {_session, id, provider} = start(context, hooks)

    payload = result(id, provider)
    assert_receive {:denied, %{"path" => "hook.txt"}, "hook gate"}
    assert payload["error"] == true
    assert payload["output"] =~ "outside host policy"
    refute File.exists?(context.marker)
    refute_received :unexpected_policy
  end

  test "rewriting without a permission decision grants no approval to the next policy", context do
    parent = self()

    hooks = [
      before_tool_call: command(nil),
      before_tool_call: fn call, ctx ->
        send(parent, {:following, call.arguments, Map.get(ctx, :approved_by)})
        :allow
      end
    ]

    {_session, id, provider} = start(context, hooks)

    payload = result(id, provider)
    assert_receive {:following, %{"path" => "hook.txt"}, nil}
    assert payload["output"] == "executed hook.txt"
    assert File.read!(context.marker) == "hook.txt"
  end

  for {decision, expected} <- [
        {:allow, "hook.txt"},
        {{:rewrite, %{"path" => "human.txt"}}, "human.txt"},
        {{:deny, "declined"}, nil}
      ] do
    test "ask with rewritten input honors #{inspect(decision)} and never executes before the answer",
         context do
      decision = unquote(Macro.escape(decision))
      expected = unquote(expected)
      parent = self()

      hooks = [
        before_tool_call: command("ask"),
        before_tool_call: fn call, ctx ->
          send(parent, {:following, call.id, call.arguments, Map.get(ctx, :approved_by)})
          :allow
        end
      ]

      {session, id, provider} = start(context, hooks)

      assert_receive {:lemieux, ^id,
                      {:tool_approval,
                       %{
                         id: "c1",
                         name: "marker",
                         arguments: %{"path" => "hook.txt"},
                         permission: %{"hook" => "hook gate", "reason" => "review rewritten path"}
                       }}}

      refute File.exists?(context.marker)
      refute_receive {:following, _, _, _}, 20
      assert [%{call_id: "c1", kind: :approval}] = Session.snapshot(session).pending
      assert length(Scripted.requests(provider)) == 1

      assert Session.resolve_tool(session, "c1", decision) == :ok
      payload = result(id, provider)

      assert_execution(context, payload, expected)

      assert Session.resolve_tool(session, "c1", :allow) == {:error, :unknown_call}
      refute_receive {:lemieux, ^id, {:tool_approval, _duplicate}}, 20
    end
  end
end
