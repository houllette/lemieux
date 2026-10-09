defmodule Lemieux.Extensions.A2UIValidationTest do
  use ExUnit.Case, async: true
  alias Lemieux.Extensions.A2UI.{Rendering, Validation}
  alias Lemieux.TUI.A2UI
  alias Lemieux.TUI.{Blocks, Theme}

  test "feedback and display share both protocol and native preparation failures" do
    source = File.read!("test/fixtures/a2ui/invalid_chart_sampler.md")
    [failure] = Validation.diagnostics(source)
    assert failure =~ "Charts and progress"
    assert failure =~ "sampleRate"
    assert failure =~ "numeric samples/second"
    assert failure =~ "0.0167"

    assert Validation.diagnostics(
             String.replace(source, ~s|"sampleRate":"1m"|, ~s|"sampleRate":0.0167|)
           ) == []

    invalid = "flowchart LR\nclick A callback"
    [failure] = Validation.diagnostics("```mermaid Request flow\n" <> invalid <> "\n```")
    assert failure =~ "line 2"

    for fixture <- ["invalid_diagram_gallery.jsonl"] do
      source = File.read!("test/fixtures/a2ui/" <> fixture)
      assert {:error, error} = Rendering.prepare(source)
      assert A2UI.rows(source) == {:error, error}
    end
  end

  test "fence recognition handles captions, tilde, incomplete drawings and ordinary examples" do
    assert Validation.diagnostics("~~~MERMAID Request\nflowchart LR\nA --> B\n~~~") == []
    assert Validation.diagnostics("````markdown\n```a2ui\n{}\n```\n````") == []
    assert Validation.diagnostics("```elixir\ntext = \"```a2ui\"\n```") == []
    [failure] = Validation.diagnostics("```mermaid Request\nflowchart LR\nA --> B\n~~")
    assert failure =~ "Missing closing fence"
    [failure] = Validation.diagnostics("````mermaid\nflowchart LR\nA --> B\n```")
    assert failure =~ "Missing closing fence"
  end

  test "feedback and retained sources stay bounded even for many or oversized drawings" do
    errors = Validation.diagnostics(String.duplicate("```a2ui\n{}\n```\n", 100))
    assert length(errors) == 4
    assert byte_size(Enum.join(errors)) < 4096
    [error] = Validation.diagnostics("```a2ui Huge\n" <> String.duplicate("x", 40_000) <> "\n```")
    assert error =~ "16 KiB"
    refute error =~ String.duplicate("x", 100)
    assert Validation.diagnostics(<<255>>) == ["Visualization text must be valid UTF-8."]
    # Reaching the local check budget alone is not a failed rendering.
    assert Validation.diagnostics(
             String.duplicate("```mermaid\nflowchart LR\nA --> B\n```\n", 33)
           ) == []
  end

  test "a valid fence at the source byte limit agrees with terminal display" do
    messages = [
      %{
        "version" => "v0.9.1",
        "createSurface" => %{
          "surfaceId" => "s",
          "catalogId" => Lemieux.Extensions.A2UI.catalog_id()
        }
      },
      %{
        "version" => "v0.9.1",
        "updateComponents" => %{
          "surfaceId" => "s",
          "components" => [%{"id" => "root", "component" => "Text", "text" => "Done"}]
        }
      },
      %{
        "version" => "v0.9.1",
        "updateDataModel" => %{"surfaceId" => "s", "value" => %{"unused" => ""}}
      }
    ]

    source = Enum.map_join(messages, "\n", &JSON.encode!/1)

    source =
      String.replace(
        source,
        ~s|"unused":""|,
        ~s|"unused":"#{String.duplicate("x", 16_384 - byte_size(source))}"|
      )

    assert byte_size(source) == 16_384
    answer = "```a2ui\n" <> source <> "\n```"
    assert Validation.diagnostics(answer) == []
    assert [{:model_ui, _}] = Blocks.rows(answer, Theme.mono())
  end
end
