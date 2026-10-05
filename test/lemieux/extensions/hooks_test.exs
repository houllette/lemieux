defmodule Lemieux.Extensions.HooksTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Hooks
  alias Lemieux.Harness
  alias Lemieux.Hooks.Command

  @moduletag :tmp_dir

  defp write(tmp_dir, document) do
    path = Path.join(tmp_dir, "hooks.json")
    File.write!(path, JSON.encode!(document))
    path
  end

  test "appends the file's command hooks after the host's", %{tmp_dir: tmp_dir} do
    path =
      write(tmp_dir, %{
        "version" => 1,
        "hooks" => %{"preToolUse" => [%{"matcher" => "bash", "command" => "./policy.sh"}]}
      })

    host = {:before_tool_call, fn _call, _context -> :allow end}

    assert {:ok, harness} = Harness.assemble(Harness.new(hooks: [host]), [{Hooks, file: path}])

    assert [^host, {:before_tool_call, %Command{command: "./policy.sh", matcher: "bash"}}] =
             harness.hooks

    assert [
             %{
               "module" => "Lemieux.Extensions.Hooks",
               "options" => %{"file" => ^path, "hooks" => 1}
             }
           ] =
             harness.applied
  end

  test "a file that cannot be read stops assembly with its message", %{tmp_dir: tmp_dir} do
    missing = Path.join(tmp_dir, "nope.json")

    assert {:error, {Hooks, message}} = Harness.assemble(Harness.new(), [{Hooks, file: missing}])
    assert message =~ "could not read hook config"
    assert message =~ missing
  end

  test "a file with an unknown event is refused rather than partly applied", %{tmp_dir: tmp_dir} do
    path = write(tmp_dir, %{"version" => 1, "hooks" => %{"onCoffee" => []}})

    assert {:error, {Hooks, message}} = Harness.assemble(Harness.new(), [{Hooks, file: path}])
    assert message =~ "unknown hook event"
  end
end
