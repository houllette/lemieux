defmodule Lemieux.CLI.StructuredResultTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.StructuredResult

  @moduletag :tmp_dir
  @schema %{
    "type" => "object",
    "additionalProperties" => false,
    "required" => ["ok"],
    "properties" => %{"ok" => %{"type" => "boolean"}}
  }

  test "valid JSON is independently validated and checkpointed after tool use", %{tmp_dir: dir} do
    provider =
      Scripted.new([
        Scripted.tool_call("read", "read", %{"path" => "input"}),
        Scripted.complete(~s({"ok":true}))
      ])

    File.write!(Path.join(dir, "input"), "read me")
    result = run(dir, @schema, provider)
    assert result.status == :ok
    assert result.json["structured_result"]["status"] == "validated"
    assert result.json["structured_result"]["value"] == %{"ok" => true}
    assert {:ok, entries} = Store.read(result.store, result.json["session_id"])

    assert Enum.any?(
             entries,
             &(&1.type == :extension_state and
                 &1.payload["namespace"] == "lemieux.structured_result")
           )

    assert length(Scripted.requests(provider)) == 2
    assert Enum.any?(hd(Scripted.requests(provider)).tools, &(Lemieux.Tool.name(&1) == "read"))
  end

  test "schema mismatch returns failure while retaining actual model text", %{tmp_dir: dir} do
    provider = Scripted.new([Scripted.complete(~s({"ok":"yes"}))])
    result = run(dir, @schema, provider)
    assert result.status == {:error, 1}
    assert result.json["exit_status"] == 1
    assert result.json["text"] == ~s({"ok":"yes"})
    assert result.json["structured_result"]["reason"] == "schema_mismatch"
    assert length(Scripted.requests(provider)) == 1
  end

  test "fenced or incomplete answers never become validated success", %{tmp_dir: dir} do
    result = run(dir, @schema, Scripted.new([Scripted.complete("```json\n{\"ok\":true}\n```")]))
    assert result.status == {:error, 1}
    assert result.json["structured_result"]["reason"] == "invalid_json"

    result =
      run(
        dir,
        @schema,
        Scripted.new([Scripted.complete(~s({"ok":true}), finish_reason: :length)]),
        ["--max-requests", "1"]
      )

    assert result.status != :ok
    assert result.json["structured_result"]["reason"] == "incomplete_turn"
  end

  test "invalid and externally referenced schemas are refused before a provider request", %{
    tmp_dir: dir
  } do
    provider = Scripted.new([])
    result = run(dir, Map.put(@schema, "$ref", "https://example.test/schema"), provider)
    assert result.status == {:error, 2}
    assert result.json["session_id"] == nil
    assert Scripted.requests(provider) == []

    assert {:error, :invalid_schema} =
             StructuredResult.new(%{
               "type" => "object",
               "properties" => %{"x" => %{"type" => "unknown"}}
             })
  end

  test "nested local references and numeric constraints are validated" do
    schema = %{
      "type" => "object",
      "$defs" => %{"count" => %{"type" => "integer", "minimum" => 1}},
      "required" => ["count"],
      "properties" => %{"count" => %{"$ref" => "#/$defs/count"}}
    }

    assert {:ok, contract} = StructuredResult.new(schema)
    assert {:ok, %{"count" => 1}} = StructuredResult.validate(contract, ~s({"count":1}))
    assert {:error, :schema_mismatch} = StructuredResult.validate(contract, ~s({"count":0}))
  end

  defp run(dir, schema, provider, flags \\ []) do
    path = Path.join(dir, "schema.json")
    File.write!(path, JSON.encode!(schema))
    store = JSONL.new(Path.join(dir, "sessions"))
    runtime = :"structured_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({Lemieux.Supervisor, name: runtime}, id: runtime))

    output =
      capture_io(fn ->
        capture_io(:stderr, fn ->
          status =
            CLI.run(
              [
                "run",
                "--config",
                "none",
                "--no-delegate",
                "--output-format",
                "json",
                "--output-schema",
                path
              ] ++ flags ++ ["work"],
              provider: provider,
              store: store,
              supervisor: runtime,
              cwd: dir,
              stdin_terminal?: true
            )

          send(self(), {:status, status})
        end)
      end)

    assert_received {:status, status}
    %{json: JSON.decode!(output), status: status, store: store}
  end
end
