defmodule Lemieux.TUI.ResourceIndexTest do
  @moduledoc false
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.TUI
  alias Lemieux.TUI.CompletionSources
  alias Lemieux.TUI.ResourceIndex

  @notes %{label: "docs:mem://notes", reference: "@docs:mem://notes", name: "notes"}
  @logo %{label: "docs:mem://logo", reference: "@docs:mem://logo", name: "logo"}

  describe "what can be offered" do
    test "only what the session would read back as the same resource, once each" do
      assert [@notes] =
               ResourceIndex.offerable([
                 %{server: "docs", uri: "mem://notes", name: "notes"},
                 %{server: "docs", uri: "mem://notes", name: "again"},
                 %{server: "docs", uri: "my notes", name: "not a URI"},
                 %{server: "two words", uri: "mem://x", name: "not a server name"}
               ])
    end
  end

  describe "matching" do
    test "ranks server:uri the way the picker ranks paths" do
      references = %{resources: %{items: [@logo, @notes], loading?: false}}

      assert [@notes] = ResourceIndex.match(references, "notes")
      assert ResourceIndex.match(%{}, "notes") == []
    end
  end

  describe "listing" do
    test "keeps an answer only for the session still being shown" do
      session = self()
      stale = spawn(fn -> :ok end)

      assert %{resources: %{items: [@notes], loading?: false}} =
               ResourceIndex.loaded(%{}, session, session, [@notes])

      assert ResourceIndex.loaded(%{}, session, stale, [@notes]) == %{}
    end

    test "asks nothing without a session, and asks a session in a task" do
      assert ResourceIndex.refresh(%{}, nil) == %{}

      session = fake_session(snapshot("01RESOURCES"))
      references = ResourceIndex.refresh(%{}, session)

      assert %{resources: %{loading?: true}} = references
      assert_receive {:mcp_resources, ^session, []}, 5_000
    end

    test "a listing that arrives is kept by the screen", %{} do
      session = self()
      state = tui(session: session)

      assert {:noreply, listed} = TUI.handle_info({:mcp_resources, session, [@notes]}, state)
      assert %{items: [@notes], loading?: false} = listed.references.resources
    end
  end

  describe "the @ menu" do
    @describetag :tmp_dir

    test "offers matching resources as references it can put on the line", %{tmp_dir: cwd} do
      state = tui(cwd: cwd)
      fuzzy = %{query: "@docs:no", matches: [], resources: [@notes]}
      state = put_in(state.references.fuzzy, fuzzy)

      assert [%{label: "docs:mem://notes — notes", value: "read @docs:mem://notes "}] =
               CompletionSources.matches("read @docs:no", state)
    end

    test "puts files first unless a colon says a resource is wanted", %{tmp_dir: cwd} do
      state = tui(cwd: cwd)

      with_files = %{query: "@note", matches: ["notes.md"], resources: [@notes]}
      state = put_in(state.references.fuzzy, with_files)

      assert [%{label: "notes.md"}, %{label: "docs:mem://notes — notes"}] =
               CompletionSources.matches("@note", state)

      with_colon = %{query: "@docs:n", matches: ["docs/notes.md"], resources: [@notes]}
      state = put_in(state.references.fuzzy, with_colon)

      assert [%{label: "docs:mem://notes — notes"}, %{label: "docs/notes.md"}] =
               CompletionSources.matches("@docs:n", state)
    end
  end
end
