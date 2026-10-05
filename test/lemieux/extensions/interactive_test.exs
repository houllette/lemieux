defmodule Lemieux.Extensions.InteractiveTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Interactive
  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tools

  test "appends ask_user to the default catalog" do
    assert {:ok, harness} = Harness.assemble(Harness.new(), [Interactive])

    assert Enum.map(harness.tools, &Tool.name/1) == ~w(read write edit bash ask_user)
  end

  test "appends it to a host's catalog" do
    assert {:ok, harness} = Harness.assemble(Harness.new(tools: [Tools.Read]), [Interactive])

    assert harness.tools == [Tools.Read, Tools.AskUser]
  end

  test "leaves a catalog that already asks alone" do
    assert {:ok, harness} =
             Harness.assemble(Harness.new(tools: [Tools.AskUser, Tools.Read]), [Interactive])

    assert harness.tools == [Tools.AskUser, Tools.Read]
  end

  test "is recorded without options" do
    assert {:ok, harness} = Harness.assemble(Harness.new(), [Interactive])

    assert [%{"module" => "Lemieux.Extensions.Interactive", "options" => %{}}] = harness.applied
  end
end
