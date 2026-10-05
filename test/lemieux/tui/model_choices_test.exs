defmodule Lemieux.TUI.ModelChoicesTest do
  use ExUnit.Case, async: true

  alias Lemieux.TUI.ModelChoices

  @catalog_now ~U[2026-09-24 00:00:00Z]

  test "active dated models lead unknown and deprecated models" do
    choices =
      ModelChoices.prepare(
        [
          "openai:gpt-4",
          "openai:unlisted-model",
          "openai:gpt-6-astra",
          "openai:gpt-6-sol",
          "openai:gpt-6-luna"
        ],
        now: @catalog_now
      )

    assert Enum.map(choices, & &1.id) == [
             "gpt-6-luna",
             "gpt-6-sol",
             "gpt-6-astra",
             "unlisted-model",
             "gpt-4"
           ]

    assert List.last(choices).label == "gpt-4 · deprecated"
  end

  test "preferences and recent selections lead, while exact search still wins" do
    choices =
      ModelChoices.prepare(
        ["openai:gpt-4", "openai:gpt-4o", "openai:gpt-6-astra", "openai:gpt-6-sol"],
        preferred: %{"openai" => "openai:gpt-4o"},
        recent: ["openai:gpt-4"],
        now: @catalog_now
      )

    assert Enum.map(choices, & &1.id) == ["gpt-4o", "gpt-4", "gpt-6-sol", "gpt-6-astra"]
    assert hd(choices).label == "gpt-4o · preferred"
    assert Enum.at(choices, 1).label == "gpt-4 · recent · deprecated"

    assert ModelChoices.completions(choices, "/model gpt-4") == [
             %{
               label: "gpt-4 · recent · deprecated",
               value: "/model gpt-4",
               deprecated?: true,
               personal?: true
             },
             %{
               label: "gpt-4o · preferred",
               value: "/model gpt-4o",
               deprecated?: false,
               personal?: true
             }
           ]
  end

  test "unknown provider models remain searchable and stable" do
    choices = ModelChoices.prepare(["ixway:zeta", "ixway:alpha"])
    assert Enum.map(choices, & &1.id) == ["alpha", "zeta"]

    assert ModelChoices.completions(choices, "/model ze") == [
             %{label: "zeta", value: "/model zeta", deprecated?: false, personal?: false}
           ]
  end

  test "stable model ids lead dated snapshots of the same model" do
    choices = ModelChoices.prepare(["openai:gpt-4o-2024-11-20", "openai:gpt-4o"])
    assert Enum.map(choices, & &1.id) == ["gpt-4o", "gpt-4o-2024-11-20"]
  end

  test "Ixway routes become tabs while automatic keeps one model per base id" do
    models = [
      "ixway:gpt-5.6-luna",
      "ixway:openai:gpt-5.6-luna",
      "ixway:openai_codex:gpt-5.6-luna",
      "ixway:coding/fast",
      "ixway:team/latest"
    ]

    metadata = %{
      "ixway:gpt-5.6-luna" => %{kind: "concrete", route: "Automatic"},
      "ixway:openai:gpt-5.6-luna" => %{kind: "concrete", route: "openai"},
      "ixway:openai_codex:gpt-5.6-luna" => %{kind: "concrete", route: "openai_codex"},
      "ixway:coding/fast" => %{kind: "intent", route: "Automatic"},
      "ixway:team/latest" => %{kind: "alias", route: "Automatic"}
    }

    choices = ModelChoices.prepare(models, metadata: metadata)

    assert ModelChoices.tabs(choices) == ["Automatic", "openai", "openai_codex"]
    assert ModelChoices.tab_label("Automatic") == "Ixway"
    assert ModelChoices.tab_label("openai_codex") == "Codex"

    assert Enum.map(ModelChoices.completions(choices, "/model "), & &1.value) == [
             "/model coding/fast",
             "/model team/latest",
             "/model gpt-5.6-luna"
           ]

    assert ModelChoices.completions(choices, "/model ", "openai_codex") == [
             %{
               label: "gpt-5.6-luna",
               value: "/model openai_codex:gpt-5.6-luna",
               deprecated?: false,
               personal?: false
             }
           ]

    assert [%{value: "/model openai_codex:gpt-5.6-luna"}] =
             ModelChoices.completions(choices, "/model openai_codex:gpt-5.6-luna")
  end

  test "a colon in an automatic model id is not mistaken for a route search" do
    choices =
      ModelChoices.prepare(
        ["ixway:llama:8b", "ixway:ollama:llama:8b"],
        metadata: %{
          "ixway:llama:8b" => %{kind: "concrete", route: "Automatic"},
          "ixway:ollama:llama:8b" => %{kind: "concrete", route: "ollama"}
        }
      )

    assert [%{value: "/model llama:8b"}] =
             ModelChoices.completions(choices, "/model llama:8b")
  end

  test "Ixway concrete models use known release dates and unknown ids sort alphabetically" do
    ids = ~w(gpt-5.6-luna unknown-z gpt-6-luna unknown-a gpt-5)

    metadata =
      Map.new(ids, fn id ->
        {"ixway:#{id}", %{kind: "concrete", route: "Automatic"}}
      end)

    choices = ModelChoices.prepare(Map.keys(metadata), metadata: metadata, now: @catalog_now)

    assert Enum.map(ModelChoices.completions(choices, "/model "), & &1.value) == [
             "/model gpt-6-luna",
             "/model gpt-5.6-luna",
             "/model gpt-5",
             "/model unknown-a",
             "/model unknown-z"
           ]

    qualified =
      Map.new(ids, fn id ->
        {"ixway:openai_codex:#{id}", %{kind: "concrete", route: "openai_codex"}}
      end)

    choices = ModelChoices.prepare(Map.keys(qualified), metadata: qualified, now: @catalog_now)

    assert Enum.map(ModelChoices.completions(choices, "/model ", "openai_codex"), & &1.value) == [
             "/model openai_codex:gpt-6-luna",
             "/model openai_codex:gpt-5.6-luna",
             "/model openai_codex:gpt-5",
             "/model openai_codex:unknown-a",
             "/model openai_codex:unknown-z"
           ]
  end

  test "an Ixway catalog release date takes precedence over the bundled fallback" do
    metadata = %{
      "ixway:gpt-5" => %{kind: "concrete", route: "Automatic"},
      "ixway:gpt-6-luna" => %{
        kind: "concrete",
        route: "Automatic",
        release_date: "2024-01-01"
      }
    }

    choices = ModelChoices.prepare(Map.keys(metadata), metadata: metadata, now: @catalog_now)

    assert Enum.map(ModelChoices.completions(choices, "/model "), & &1.value) == [
             "/model gpt-5",
             "/model gpt-6-luna"
           ]
  end
end
