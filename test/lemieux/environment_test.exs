defmodule Lemieux.EnvironmentTest do
  use ExUnit.Case, async: true

  alias Lemieux.Environment

  describe "from_context/1" do
    test "returns the environment the session put in the context" do
      environment = {LemieuxTest.ScriptedEnvironment, []}
      assert Environment.from_context(%{cwd: "/tmp", environment: environment}) == environment
      assert Environment.from_context(%{environment: Environment.local()}) == Environment.Local
    end

    # A context without one used to get `Environment.local/0`, so a host that
    # forgot the option ran the model's commands unconfined on its own
    # machine and nothing said so.
    test "a context built without one raises and says what to pass" do
      error =
        assert_raise ArgumentError, fn ->
          Environment.from_context(%{cwd: "/tmp", session_id: "s1", call_id: "c1"})
        end

      assert error.message =~ ":environment"
      assert error.message =~ "Lemieux.Environment.local()"
    end
  end

  describe "list_dir/3, which the behaviour makes optional" do
    test "asks a module the VM has not loaded yet, rather than assuming it cannot" do
      # `function_exported?/3` answers about loaded modules, and loading is
      # lazy. Unloaded first so the test is about the dispatcher rather than
      # about whatever else happened to load this module already.
      :code.purge(LemieuxTest.ListingEnvironment)
      :code.delete(LemieuxTest.ListingEnvironment)
      refute :erlang.module_loaded(LemieuxTest.ListingEnvironment)

      assert Environment.list_dir(LemieuxTest.ListingEnvironment, "/tmp", "lib") ==
               {:ok, [%{name: "lib", type: :directory}]}
    end

    test "carries host state through to the callback" do
      assert Environment.list_dir({LemieuxTest.ListingEnvironment, :state}, "/tmp", "src") ==
               {:ok, [%{name: "src", type: :directory}]}
    end

    test "an environment without the callback says so" do
      assert Environment.list_dir(LemieuxTest.HTTPAgent, "/tmp", "lib") ==
               {:error, :unsupported}
    end
  end
end
