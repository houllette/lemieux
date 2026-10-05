defmodule Lemieux.Hooks.CredentialsTest do
  @moduledoc """
  What a command hook inherits from the VM's environment.

  Not async: the tests put a variable in this VM's process environment, which
  every concurrently running test would also see.
  """
  use ExUnit.Case, async: false

  alias Lemieux.Environment.Local
  alias Lemieux.Hooks.Command

  @moduletag :tmp_dir

  @variable "LEMIEUX_HOOK_TEST_TOKEN"

  setup do
    System.put_env(@variable, "s3cret")
    on_exit(fn -> System.delete_env(@variable) end)
  end

  # What the hook saw, reported back as JSON on stdout.
  defp seen(command, context) do
    script = ~s(printf '{"seen":"%s"}' "${#{@variable}:-unset}")

    assert {:ok, %{"seen" => seen}} =
             command |> Map.put(:command, script) |> Command.run(%{}, context)

    seen
  end

  defp context(tmp_dir, environment),
    do: %{cwd: tmp_dir, session_id: "s", environment: environment}

  test "a hook follows the credential policy of the environment tools run in",
       %{tmp_dir: tmp_dir} do
    hook = %Command{command: ""}

    assert seen(hook, context(tmp_dir, Local.new(credentials: true))) == "unset"
    assert seen(hook, context(tmp_dir, Local.new())) == "s3cret"
    assert seen(hook, %{cwd: tmp_dir, session_id: "s"}) == "s3cret"
  end

  test "a policy on the hook itself wins, and so do the hook's own variables",
       %{tmp_dir: tmp_dir} do
    inheriting = context(tmp_dir, Local.new())

    assert seen(%Command{command: "", credentials: {:scrub, []}}, inheriting) == "unset"
    assert seen(%Command{command: "", credentials: {:scrub, [@variable]}}, inheriting) == "s3cret"

    own = %Command{command: "", credentials: {:scrub, []}, env: %{@variable => "given"}}
    assert seen(own, inheriting) == "given"
  end
end
