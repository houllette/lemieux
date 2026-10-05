defmodule Lemieux.ToolsTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tool
  alias Lemieux.Tools

  defmodule Nested do
    @behaviour Lemieux.Tool
    def name, do: "nested"
    def description, do: "Calls a tool under the current host policy"
    def schema, do: %{"type" => "object", "properties" => %{}}

    def run(_args, context) do
      result =
        Tools.run(
          [Lemieux.Tools.Read],
          context.hooks,
          %{id: "inner", name: "read", arguments: %{"path" => "never-read"}},
          context
        )

      {:ok, result.output}
    end
  end

  test "composed tools receive the effective hooks, replacing any stale context policy" do
    hooks = [
      before_tool_call: fn call, _ ->
        if call.name == "read", do: {:deny, "host denies nested read"}, else: :allow
      end
    ]

    result =
      Tools.run([Nested], hooks, %{id: "outer", name: "nested", arguments: %{}}, %{
        tool_output_bytes: 1000,
        hooks: []
      })

    refute result.error?
    assert result.output == "denied: host denies nested read"
  end

  @forbidden_top_level_keywords ~w(anyOf oneOf allOf enum const not)

  test "default interactive tools have OpenAI- and Anthropic-compatible schema roots" do
    assert {:ok, harness} =
             Lemieux.Harness.assemble(Lemieux.Harness.new(), [Lemieux.Extensions.Interactive])

    for tool <- harness.tools do
      schema = Tool.schema(tool)
      assert schema["type"] == "object"

      for keyword <- @forbidden_top_level_keywords do
        refute Map.has_key?(schema, keyword),
               "#{Tool.name(tool)} uses provider-incompatible top-level #{keyword}"
      end
    end
  end

  describe "default/1" do
    alias Lemieux.Tools.{Bash, Edit, Read, Write}

    test "except: drops the named defaults and keeps the others in order" do
      assert Tools.default(except: ["write"]) == [Read, Edit, Bash]
      assert Tools.default(except: ["bash", "read"]) == [Write, Edit]
      assert Tools.default(except: []) == Tools.default()
      assert Tools.default([]) == Tools.default()
    end

    test "a name that is not a default is an error, not a silent no-op" do
      error = assert_raise(ArgumentError, fn -> Tools.default(except: ["wrte"]) end)
      assert error.message =~ ~s("wrte")
      assert error.message =~ "read, write, edit, bash"

      assert_raise ArgumentError, fn -> Tools.default(except: [:write]) end
      assert_raise ArgumentError, fn -> Tools.default(except: "write") end
    end

    test "an unknown option is rejected rather than ignored" do
      assert_raise ArgumentError, ~r/:only/, fn -> Tools.default(only: ["read"]) end
    end
  end

  defmodule Echo do
    @behaviour Lemieux.Tool
    def name, do: "echo"
    def description, do: "Says what it was given"
    def schema, do: %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}
    def run(%{"text" => text}, _context), do: {:ok, text}
  end

  test "post-tool hook feedback reaches the result the model reads" do
    hooks = [
      after_tool_call: fn _call, _result, _context -> {:feedback, "the formatter disagrees"} end,
      after_tool_call: fn _call, _result, _context -> :ok end
    ]

    call = %{id: "c1", name: "echo", arguments: %{"text" => "done"}}
    result = Tools.run([Echo], hooks, call, %{tool_output_bytes: 1000})

    refute result.error?
    assert result.output == "done\n\n[hook] the formatter disagrees"
    assert result.output_bytes == byte_size(result.output)
  end

  test "a post-tool hook with nothing to say leaves the result byte for byte" do
    hooks = [after_tool_call: fn _call, _result, _context -> :ok end]
    call = %{id: "c1", name: "echo", arguments: %{"text" => "done"}}

    assert %{output: "done", error?: false} =
             Tools.run([Echo], hooks, call, %{tool_output_bytes: 1000})
  end

  test "malformed arguments become a precise model-visible result without running the tool" do
    {:error, decode_error} = JSON.decode(~s({"path":))

    call = %{
      id: "call-1",
      name: "read",
      arguments: %{},
      argument_error: decode_error
    }

    result = Tools.run([Lemieux.Tools.Read], [], call, %{}, fn _text -> :ok end)

    assert result.error?
    assert result.outcome == :invalid_arguments
    assert result.arguments == %{}
    assert result.output =~ "invalid tool arguments"
    assert result.output =~ "JSON"
  end
end
