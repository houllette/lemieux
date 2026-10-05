defmodule Lemieux.Conversation.CommandTest do
  @moduledoc """
  The registry and the helpers every command module is built from, with no
  session and no front end anywhere near them.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command
  alias Lemieux.Conversation.Command.Builtin

  defmodule Wave do
    @moduledoc false
    @behaviour Lemieux.Conversation.Command

    @impl Lemieux.Conversation.Command
    def spec do
      %{
        name: "wave",
        aliases: ["hi"],
        description: "wave at the room",
        accepts_arguments?: true,
        action: {:wave, nil}
      }
    end

    @impl Lemieux.Conversation.Command
    def parse(whom, _conversation), do: [{:wave, String.trim(whom)}]

    @impl Lemieux.Conversation.Command
    def perform(acc, _host, _effect), do: acc
  end

  # A host command that takes a built-in's alias rather than its name.
  defmodule Colour do
    @moduledoc false
    @behaviour Lemieux.Conversation.Command

    @impl Lemieux.Conversation.Command
    def spec, do: %{name: "colour", description: "the host's palette", action: :host_colour}

    @impl Lemieux.Conversation.Command
    def parse(_arguments, _conversation), do: [:host_colour]

    @impl Lemieux.Conversation.Command
    def perform(acc, _host, _effect), do: acc
  end

  defmodule Halfway do
    @moduledoc false
    def spec, do: %{name: "halfway", description: "no parse or perform", action: :halfway}
  end

  defmodule Underspecified do
    @moduledoc false
    @behaviour Lemieux.Conversation.Command

    @impl Lemieux.Conversation.Command
    def spec, do: %{name: "underspecified"}

    @impl Lemieux.Conversation.Command
    def parse(_arguments, _conversation), do: []

    @impl Lemieux.Conversation.Command
    def perform(acc, _host, _effect), do: acc
  end

  describe "the registry" do
    test "nothing extra is the built-ins, in help order" do
      assert Command.registry([]) == {:ok, Builtin.all()}

      # Everyday first, research last — see `Builtin`'s moduledoc.
      assert Enum.map(Builtin.all(), &Command.spec!(&1).name) |> Enum.take(3) ==
               ~w(model provider effort)
    end

    test "the Elixir commands are not built-ins but a list a host hands on" do
      names = Enum.map(Builtin.all(), &Command.spec!(&1).name)

      assert Enum.map(Builtin.elixir(), &Command.spec!(&1).name) == ~w(elixir attach detach)
      assert Enum.all?(~w(elixir attach detach), &(&1 not in names))
    end

    test "host modules go ahead of the built-ins" do
      assert {:ok, [Wave | rest]} = Command.registry([Wave])
      assert rest == Builtin.all()
    end

    test "a host module shadows the built-in whose name or alias it takes" do
      assert {:ok, commands} = Command.registry([Colour])

      assert Colour in commands
      refute Command.Color in commands
      assert Command.find(commands, "color") == nil
      assert Command.find(commands, "colour") == Colour
    end

    test "every problem is named at once, and registry!/1 raises with them" do
      assert Command.registry([Halfway, Underspecified, :nope]) ==
               {:error,
                [
                  ":nope does not implement Lemieux.Conversation.Command",
                  "Lemieux.Conversation.CommandTest.Halfway does not implement " <>
                    "Lemieux.Conversation.Command",
                  "Lemieux.Conversation.CommandTest.Underspecified.spec/0 must return a map " <>
                    "with :name, :description and :action; got %{name: \"underspecified\"}"
                ]}

      assert_raise ArgumentError, ~r/commands: :nope does not implement/, fn ->
        Command.registry!([:nope])
      end
    end

    test "every built-in is a command, and no two answer to the same name" do
      names = Enum.flat_map(Builtin.all(), &Command.names/1)

      assert Command.registry(Builtin.all()) |> elem(0) == :ok
      assert Enum.uniq(names) == names
    end
  end

  describe "a spec" do
    test "is filled in with its defaults, and the policy action is always routable" do
      spec = Command.spec!(Wave)

      assert spec.aliases == ["hi"]
      assert spec.accepts_arguments?
      assert spec.actions == [{:wave, nil}]
      assert spec.subcommands == []
      refute spec.hidden?

      assert Command.spec!(Command.Model).actions == [:model_status, {:set_model, "SPEC"}]
      assert Command.spec!(Command.Habs).hidden?
    end

    test "names are the name and every alias" do
      assert Command.names(Wave) == ["wave", "hi"]
      assert Command.names(Command.Quit) == ["quit", "exit"]
    end
  end

  describe "finding the owner of an effect" do
    test "matches an atom exactly and a tuple by tag and size" do
      assert Command.shape?(:compact, :compact)
      refute Command.shape?(:compact, :clear)
      assert Command.shape?({:set_model, "SPEC"}, {:set_model, "anthropic:haiku"})
      refute Command.shape?({:deny, nil, nil}, {:deny, "a reason"})
      refute Command.shape?({:wave, nil}, :wave)
    end

    test "names the module whose actions list the shape, or nobody" do
      commands = Command.registry!([Wave])

      assert Command.owner(commands, {:wave, "alice"}) == Wave
      assert Command.owner(commands, {:set_model, "x"}) == Command.Model
      assert Command.owner(commands, {:deny, "t1", nil}) == Command.Deny
      assert Command.owner(commands, {:say, "a line"}) == nil
      assert Command.owner(commands, :ready) == nil

      assert Command.action?(commands, :compact)
      refute Command.action?(commands, {:prompt, "hello"})
    end
  end

  describe "what is listed" do
    test "leaves out hidden commands and the ones the policy denies" do
      policy = fn
        :compact -> {:deny, "no compaction here"}
        _action -> :allow
      end

      listed = Command.listed(Builtin.all(), policy)
      names = Enum.map(listed, & &1.name)

      refute "compact" in names
      refute "habs" in names
      refute "refresh" in names
      assert "help" in names
      assert "approve" in names
    end
  end

  describe "the parse helpers" do
    test "wait/1 is a line and nothing else, so the prompt is not reprinted mid-turn" do
      assert Command.wait() == [{:say, "wait for it to finish first"}]
      assert Command.wait("not now") == [{:say, "not now"}]
    end

    test "argued/3 asks when given nothing and sets when given something" do
      assert Command.argued("", :name_status, :set_name) == [:name_status]
      assert Command.argued("   ", :name_status, :set_name) == [:name_status]
      assert Command.argued(" holden ", :name_status, :set_name) == [{:set_name, "holden"}]
    end

    test "Conversation.ready_unless_busy/2 reprints the prompt only between turns" do
      idle = Conversation.new()
      assert {^idle, [{:say, "x"}, :ready]} = Conversation.ready_unless_busy(idle, [{:say, "x"}])

      busy = %{idle | busy?: true}
      assert {^busy, [{:say, "x"}]} = Conversation.ready_unless_busy(busy, [{:say, "x"}])
    end
  end
end
