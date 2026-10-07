defmodule Mix.Tasks.LmxTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lmx
  alias Mix.Tasks.Lmx.Tui

  # A runner that records what it was given and answers `result`, and a
  # configure that does nothing: the real one replaces the VM's log handler,
  # which is this whole test run's.
  defp stub(result) do
    caller = self()

    fn argv, opts ->
      send(caller, {:ran, argv, opts})
      result
    end
  end

  # Two expressions rather than `send(...) && :ok`: `send/2` returns its
  # message, so the `&&` was a constant conditional, and Elixir 1.20.4's type
  # checker says so — a warning `mix test --warnings-as-errors` turns into a
  # failed suite.
  defp configured do
    fn ->
      send(self(), :configured)
      :ok
    end
  end

  describe "mix lmx" do
    test "passes the arguments through untouched, the way the binary takes them" do
      for argv <- [
            ["run", "Summarize this repository"],
            ["log", "wayne-gretzky"],
            ["help", "models"],
            ["--version"],
            ["-C", "../elsewhere", "explain"],
            []
          ] do
        assert Lmx.run_with(argv, stub(:ok), configured()) == :ok
        assert_received :configured
        assert_received {:ran, ^argv, _opts}
      end
    end

    test "hints name the command a source checkout has" do
      Lmx.run_with(["run", "hi"], stub(:ok), configured())

      assert_received {:ran, _argv, opts}
      assert Lemieux.CLI.program(opts) == "mix lmx"
      assert opts[:program] == "mix lmx"
    end

    # `main/1` would halt the VM, and Mix with it; the status leaves as an
    # exit Mix turns into the process's own.
    test "a failing command exits with its status instead of halting" do
      assert catch_exit(Lmx.run_with(["run"], stub({:error, 2}), configured())) ==
               {:shutdown, 2}
    end

    test "the source host's options are the program name, and the repository root only " <>
           "from the distribution host" do
      assert Lmx.source_host_options() == [program: "mix lmx"]
    end

    test "starts the application before running, so the runtime's dependencies are up" do
      assert "app.start" in Mix.Task.requirements(Lmx)
      assert Mix.Task.shortdoc(Lmx) =~ "any lmx command"
    end
  end

  describe "mix lmx.tui" do
    test "is mix lmx tui" do
      assert Tui.run_with(["--model", "ollama:x"], stub(:ok), configured()) == :ok
      assert_received {:ran, ["tui", "--model", "ollama:x"], opts}
      assert opts[:program] == "mix lmx"
    end
  end
end
