# Compile the fixture before registering the async test module: ExUnit can
# start its tests while later modules in this file are still being compiled.
defmodule Lemieux.TUI.KeysTest.Vi do
  @moduledoc false
  @behaviour Lemieux.TUI.Keys

  alias Lemieux.TUI.Keys

  @impl Keys
  def action(%{code: "k", modifiers: []}), do: :scroll_up
  def action(%{code: "j", modifiers: []}), do: :scroll_down
  def action(%{code: "x", modifiers: []}), do: :launch
  def action(key), do: Keys.action(key)
end

defmodule Lemieux.TUI.KeysTest do
  @moduledoc """
  The key table on its own, with no screen behind it: what a description
  parses to, what a map is refused for, and that the shipped table is the
  one the screen's own tests press on.

  Unguarded like the module, because a config file naming a key is checked
  on machines that never installed the terminal dependency.
  """

  use ExUnit.Case, async: true

  alias Lemieux.TUI.Keys

  defp key(code, modifiers \\ []), do: %{code: code, modifiers: modifiers}

  describe "the shipped bindings" do
    test "are the ones the CLI reference lists" do
      assert Keys.action(key("c", ["ctrl"])) == :interrupt
      assert Keys.action(key("enter")) == :submit
      assert Keys.action(key("up")) == :previous
      assert Keys.action(key("down")) == :next
      assert Keys.action(key("up", ["shift"])) == :scroll_up
      assert Keys.action(key("down", ["shift"])) == :scroll_down
      assert Keys.action(key("page_up")) == :page_up
      assert Keys.action(key("page_down")) == :page_down
      assert Keys.action(key("tab")) == :complete
      assert Keys.action(key("esc")) == :dismiss
      assert Keys.action(key("z", ["alt"])) == :revoke_steer
    end

    test "leave every other key to the editor" do
      assert Keys.action(key("c")) == :forward
      assert Keys.action(key("w", ["ctrl"])) == :forward
      assert Keys.action(key("right", ["shift"])) == :forward
      assert Keys.action(key("backspace")) == :forward
      assert Keys.action(key(nil)) == :forward
    end

    test "name a modifier set exactly" do
      assert Keys.action(key("up", ["ctrl"])) == :forward
      assert Keys.action(key("up", ["ctrl", "shift"])) == :forward
    end

    test "ignore the modifiers the grammar cannot name" do
      assert Keys.action(key("c", ["ctrl", "super"])) == :interrupt
    end

    test "read an upper-case character as the key it is on" do
      assert Keys.action(key("C", ["ctrl"])) == :interrupt
    end

    test "are what the data form holds when nothing overrides them" do
      assert Keys.to_map(Keys.default()) == %{
               "ctrl-c" => "interrupt",
               "enter" => "submit",
               "up" => "previous",
               "down" => "next",
               "alt-up" => "previous",
               "alt-down" => "next",
               "shift-up" => "scroll_up",
               "shift-down" => "scroll_down",
               "page_up" => "page_up",
               "page_down" => "page_down",
               "tab" => "complete",
               "alt-1" => "select_queued",
               "alt-2" => "select_queued",
               "alt-3" => "select_queued",
               "alt-4" => "select_queued",
               "alt-5" => "select_queued",
               "alt-6" => "select_queued",
               "alt-7" => "select_queued",
               "alt-8" => "select_queued",
               "alt-9" => "select_queued",
               "alt-e" => "revise_queued",
               "alt-u" => "unstage_queued",
               "alt-z" => "revoke_steer",
               "esc" => "dismiss",
               "ctrl-j" => "newline",
               "ctrl-o" => "pager",
               "ctrl-r" => "history_search",
               "ctrl-g" => "external_editor",
               "ctrl-v" => "paste_image",
               "back_tab" => "cycle_mode",
               "shift-back_tab" => "cycle_mode",
               "alt-n" => "toggle_notifications"
             }
    end

    test "every action is bound to something" do
      bound = Keys.default() |> Keys.to_map() |> Map.values() |> Enum.map(&String.to_atom/1)

      assert Enum.sort(Enum.uniq(bound)) == Enum.sort(Keys.actions())
    end
  end

  describe "the vocabulary" do
    test "is closed, and the names a file may use are it plus forward" do
      assert Keys.actions() == [
               :interrupt,
               :submit,
               :previous,
               :next,
               :scroll_up,
               :scroll_down,
               :page_up,
               :page_down,
               :complete,
               :select_queued,
               :revise_queued,
               :unstage_queued,
               :revoke_steer,
               :dismiss,
               :newline,
               :pager,
               :history_search,
               :external_editor,
               :paste_image,
               :cycle_mode,
               :toggle_notifications
             ]

      assert Keys.names() == Enum.map(Keys.actions(), &Atom.to_string/1) ++ ["forward"]
    end
  end

  describe "from_map/1" do
    test "overrides key by key, and the rest keep their default" do
      assert {:ok, keys} = Keys.from_map(%{"ctrl-j" => "submit", "enter" => "forward"})

      assert Keys.action(keys, key("j", ["ctrl"])) == :submit
      assert Keys.action(keys, key("enter")) == :forward
      assert Keys.action(keys, key("c", ["ctrl"])) == :interrupt
      assert Keys.action(keys, key("page_up")) == :page_up
    end

    test "an action may sit on more than one key" do
      assert {:ok, keys} = Keys.from_map(%{"shift-up" => "page_up"})

      assert Keys.action(keys, key("up", ["shift"])) == :page_up
      assert Keys.action(keys, key("page_up")) == :page_up
    end

    test "modifiers join in any order and any case" do
      assert {:ok, keys} = Keys.from_map(%{"Shift-Ctrl-Up" => "page_up"})

      assert Keys.action(keys, key("up", ["ctrl", "shift"])) == :page_up
      assert Keys.action(keys, key("up", ["shift", "ctrl"])) == :page_up
      assert Keys.to_map(keys)["ctrl-shift-up"] == "page_up"
    end

    test "a hyphen is a key, and space has a name" do
      assert {:ok, keys} =
               Keys.from_map(%{"-" => "dismiss", "ctrl--" => "page_up", "alt-space" => "submit"})

      assert Keys.action(keys, key("-")) == :dismiss
      assert Keys.action(keys, key("-", ["ctrl"])) == :page_up
      assert Keys.action(keys, key(" ", ["alt"])) == :submit
      assert Keys.to_map(keys)["alt-space"] == "submit"
    end

    test "names every bad key and unknown action at once" do
      assert {:error, problems} =
               Keys.from_map(%{
                 "ctl-x" => "submit",
                 "ctrl-" => "submit",
                 "ctrl-ctrl-x" => "submit",
                 "escape" => "dismiss",
                 "ctrl-y" => "launch",
                 "ctrl-z" => 7
               })

      assert Enum.any?(problems, &(&1 =~ ~r/ctl-x.*ctl is not a modifier/))
      assert Enum.any?(problems, &(&1 =~ ~r/"ctrl-".*no key/))
      assert Enum.any?(problems, &(&1 =~ ~r/ctrl-ctrl-x.*twice/))
      assert Enum.any?(problems, &(&1 =~ ~r/escape.*not a key/))
      assert Enum.any?(problems, &(&1 =~ ~r/ctrl-y.*"launch" is not an action/))
      assert Enum.any?(problems, &(&1 =~ ~r/ctrl-z.*7.*not an action/))
      assert length(problems) == 6
    end

    test "two spellings of one key cannot disagree" do
      assert {:error, [problem]} =
               Keys.from_map(%{"ctrl-shift-up" => "page_up", "shift-ctrl-up" => "scroll_up"})

      assert problem =~ "ctrl-shift-up"
      assert problem =~ "shift-ctrl-up"
      assert problem =~ "same key"

      assert {:ok, _keys} =
               Keys.from_map(%{"ctrl-shift-up" => "page_up", "shift-ctrl-up" => "page_up"})
    end

    test "refuses to leave interrupt bound to nothing" do
      assert {:error, [problem]} = Keys.from_map(%{"ctrl-c" => "forward"})
      assert problem =~ "interrupt"

      assert {:error, [problem]} = Keys.from_map(%{"ctrl-c" => "submit"})
      assert problem =~ "interrupt"

      assert {:ok, keys} = Keys.from_map(%{"ctrl-c" => "submit", "ctrl-x" => "interrupt"})
      assert Keys.action(keys, key("x", ["ctrl"])) == :interrupt
      assert Keys.action(keys, key("c", ["ctrl"])) == :submit
    end

    test "refuses what is not a map of strings" do
      assert {:error, [problem]} = Keys.from_map(["ctrl-j"])
      assert problem =~ "map"

      assert {:error, [problem]} = Keys.from_map(%{7 => "submit"})
      assert problem =~ "7"
    end

    test "round-trips through to_map/1 and through JSON" do
      map = %{"ctrl-j" => "submit", "enter" => "forward", "alt-space" => "page_down"}

      assert {:ok, keys} = Keys.from_map(map)
      rendered = Keys.to_map(keys)
      assert Map.take(rendered, Map.keys(map)) == map

      assert {:ok, again} = rendered |> JSON.encode!() |> JSON.decode!() |> Keys.from_map()
      assert again == keys
    end
  end

  describe "from_map!/1" do
    test "raises with every problem for a map that came from code" do
      assert_raise ArgumentError, ~r/keys: .*ctl-x.*/, fn ->
        Keys.from_map!(%{"ctl-x" => "submit"})
      end
    end
  end

  describe "action/2" do
    test "nil is the shipped table, a struct is its own, a module is asked" do
      assert Keys.action(nil, key("enter")) == :submit

      assert {:ok, keys} = Keys.from_map(%{"enter" => "forward"})
      assert Keys.action(keys, key("enter")) == :forward

      assert Keys.action(Lemieux.TUI.KeysTest.Vi, key("k")) == :scroll_up
      assert Keys.action(Lemieux.TUI.KeysTest.Vi, key("enter")) == :submit
    end

    test "a module's answer outside the vocabulary comes back tagged, not trusted" do
      assert Keys.action(Lemieux.TUI.KeysTest.Vi, key("x")) == {:unknown, :launch}
    end
  end
end
