defmodule Lemieux.Extensions.ElixirTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Interactive
  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tools

  test "the catalog becomes the evaluator alone" do
    assert {:ok, harness} = Harness.assemble(Harness.new(), [Lemieux.Extensions.Elixir])

    assert harness.tools == [Tools.Eval]
  end

  test "keeps ask_user from an interactive host and drops everything else" do
    web = Tools.WebFetch.new()

    assert {:ok, harness} =
             Harness.assemble(Harness.new(tools: Tools.default() ++ [web]), [
               Interactive,
               Lemieux.Extensions.Elixir
             ])

    assert Enum.map(harness.tools, &Tool.name/1) == ~w(elixir ask_user)
  end

  test "applied before the interactive extension, the question tool still joins" do
    assert {:ok, harness} =
             Harness.assemble(Harness.new(), [Lemieux.Extensions.Elixir, Interactive])

    assert harness.tools == [Tools.Eval, Tools.AskUser]
  end

  describe "the commands that go with it" do
    alias Lemieux.Conversation
    alias Lemieux.Conversation.Command.Builtin

    test "are offered only when the host hands them to the extension" do
      assert {:ok, bare} = Harness.assemble(Harness.new(), [Lemieux.Extensions.Elixir])
      assert bare.commands == []

      assert {:ok, offered} =
               Harness.assemble(Harness.new(), [
                 {Lemieux.Extensions.Elixir, commands: Builtin.elixir()}
               ])

      assert offered.commands == Builtin.elixir()
      assert offered.tools == [Tools.Eval]
    end

    # An ordinary session in an Elixir project: `/elixir` is there to switch
    # to the profile when it is wanted, and the catalog is left as it was.
    test "can be offered without narrowing the catalog" do
      assert {:ok, harness} =
               Harness.assemble(Harness.new(tools: Tools.default()), [
                 {Lemieux.Extensions.Elixir, profile: false, commands: Builtin.elixir()}
               ])

      assert harness.tools == Tools.default()
      assert harness.commands == Builtin.elixir()
    end

    test "reach the conversation, where they are listed and parsed" do
      {:ok, harness} =
        Harness.assemble(Harness.new(), [
          {Lemieux.Extensions.Elixir, profile: false, commands: Builtin.elixir()}
        ])

      conversation = Conversation.new(model: "test:model", commands: harness.commands)

      assert Conversation.help(conversation) =~ "/elixir"

      assert {_conversation, [{:attach, "myapp"}]} =
               Conversation.input(conversation, "/attach myapp")

      refute Conversation.help() =~ "/elixir"
    end

    test "are not offered twice when two applications name them" do
      assert {:ok, harness} =
               Harness.assemble(Harness.new(), [
                 {Lemieux.Extensions.Elixir, profile: false, commands: Builtin.elixir()},
                 {Lemieux.Extensions.Elixir, commands: Builtin.elixir()}
               ])

      assert harness.commands == Builtin.elixir()
    end

    test "refuse options that are not what they say" do
      assert {:error, {Lemieux.Extensions.Elixir, _reason}} =
               Harness.assemble(Harness.new(), [{Lemieux.Extensions.Elixir, commands: "elixir"}])

      assert {:error, {Lemieux.Extensions.Elixir, _reason}} =
               Harness.assemble(Harness.new(), [{Lemieux.Extensions.Elixir, profile: :sometimes}])
    end
  end
end
