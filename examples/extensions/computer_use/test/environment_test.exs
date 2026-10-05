defmodule LemieuxComputerUse.EnvironmentTest do
  use ExUnit.Case, async: false

  test "explicit env-file loads process-visible keys without overriding host environment" do
    key = "LMX_COMPUTER_USE_TEST_SECRET"
    previous = System.get_env(key)
    path = Path.join(System.tmp_dir!(), "lmx-browser-env-#{System.unique_integer([:positive])}")
    File.write!(path, key <> "=test-only-value\n")

    on_exit(fn ->
      File.rm(path)
      if previous, do: System.put_env(key, previous), else: System.delete_env(key)
    end)

    System.delete_env(key)
    assert :ok = Mix.Tasks.Lmx.Browser.load_env(path)
    assert System.get_env(key) == "test-only-value"
    System.put_env(key, "host-wins")
    assert :ok = Mix.Tasks.Lmx.Browser.load_env(path)
    assert System.get_env(key) == "host-wins"
  end
end
