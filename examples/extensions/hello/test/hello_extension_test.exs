defmodule HelloExtensionTest do
  use ExUnit.Case, async: true
  alias Lemieux.Providers.Scripted

  test "the same options work in a Mix host and a CLI bundle" do
    assert HelloExtension.init(note: "Use the tool") ==
             HelloExtension.init(config: %{"note" => "Use the tool"})

    assert {:error, _} = HelloExtension.init(config: %{"note" => 7})
  end

  test "a scripted session calls the real tool and records its result" do
    name = :hello_extension_test_runtime
    start_supervised!({Lemieux.Supervisor, name: name})

    provider =
      Scripted.new([
        Scripted.tool_call("count", "word_count", %{"text" => "one two three"}),
        Scripted.complete("3 words")
      ])

    {:ok, harness} = Lemieux.Harness.assemble(Lemieux.Harness.new(tools: []), [HelloExtension])

    directory =
      Path.join(System.tmp_dir!(), "hello-extension-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf!(directory) end)

    {:ok, session} =
      Lemieux.start_session(
        supervisor: name,
        provider: provider,
        model: "test:model",
        store: Lemieux.Store.JSONL.new(directory),
        harness: harness,
        max_requests: 2
      )

    assert {:ok, result} = Lemieux.Testing.prompt(session, "Count one two three")
    assert result.stop_reason == :stop

    assert Enum.any?(
             result.entries,
             &(&1.type == :tool_result and &1.payload["output"] == "3 words")
           )

    assert length(Scripted.requests(provider)) == 2
  end
end
