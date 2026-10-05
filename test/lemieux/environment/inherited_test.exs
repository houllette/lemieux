defmodule Lemieux.Environment.InheritedTest do
  # A VM a release started is not started from the person's environment:
  # erlexec puts the release's ERTS first on PATH and sets BINDIR, ROOTDIR,
  # EMU and PROGNAME. The person's commands, hooks and MCP servers inherited
  # all of it, and their own `erl` booted the release's ERTS and stopped with
  # "cannot get bootfile". The host says what to give back, once
  # (`Lemieux.Environment.Inherited.put/1`); everything that starts a process
  # for the person applies it.
  #
  # Not async: the changes are the VM's, and a test that records some would
  # hand them to every command another test runs meanwhile.
  use ExUnit.Case, async: false

  alias Lemieux.Conversation.Shell
  alias Lemieux.Environment.Inherited
  alias Lemieux.Environment.Local
  alias Lemieux.Hooks.Command
  alias Lemieux.MCP.Transport.Stdio

  @moduletag :tmp_dir

  @release_only "LMX_INHERITED_TEST_RELEASE_ONLY"

  setup %{tmp_dir: tmp_dir} do
    previous = Inherited.get()
    System.put_env(@release_only, "set for the VM")

    on_exit(fn ->
      Inherited.put(previous)
      System.delete_env(@release_only)
    end)

    # A program only the person's PATH has: what `erl` is to a person whose
    # VM put another first.
    bin = Path.join(tmp_dir, "person-bin")
    File.mkdir_p!(bin)
    tool = Path.join(bin, "lmx-inherited-probe")
    File.write!(tool, "#!/bin/sh\necho \"the person's own tool\"\n")
    File.chmod!(tool, 0o755)

    %{bin: bin, tool: tool, person_path: bin <> ":" <> System.get_env("PATH", "")}
  end

  describe "overrides/3" do
    test "sets what the host gives back, removes what it names, leaves the rest" do
      env = %{
        "PATH" => "/rel/erts-17/bin:/rel/bin:/usr/bin",
        "BINDIR" => "/rel/erts-17/bin",
        "ERL_FLAGS" => "+S 2",
        "HOME" => "/home/someone"
      }

      changes = %{"PATH" => "/usr/bin", "BINDIR" => nil, "ROOTDIR" => nil}

      assert Inherited.overrides(:inherit, env, changes) ==
               [{"BINDIR", false}, {"PATH", "/usr/bin"}]
    end

    test "a change that already holds changes nothing" do
      env = %{"PATH" => "/usr/bin", "EMU" => "beam"}
      assert Inherited.overrides(:inherit, env, %{"PATH" => "/usr/bin", "ROOTDIR" => nil}) == []
      assert Inherited.overrides(:inherit, env, %{}) == []
    end

    test "the credential policy still withholds, from what the changes leave" do
      env = %{"PATH" => "/rel/bin:/usr/bin", "OPENAI_API_KEY" => "k", "HOME" => "/h"}
      changes = %{"PATH" => "/usr/bin", "RESTORED_TOKEN" => "t"}

      assert Inherited.overrides({:scrub, []}, env, changes) == [
               {"OPENAI_API_KEY", false},
               {"PATH", "/usr/bin"},
               {"RESTORED_TOKEN", false}
             ]
    end
  end

  describe "put/1" do
    test "refuses what no operating system could pass on" do
      for changes <- [
            %{"" => "x"},
            %{"A=B" => "x"},
            %{"NUL\0NAME" => "x"},
            %{"PATH" => "a\0b"},
            %{"PATH" => :atom}
          ] do
        assert_raise ArgumentError, fn -> Inherited.put(changes) end
      end
    end

    test "replaces what was recorded" do
      :ok = Inherited.put(%{"PATH" => "/a"})
      :ok = Inherited.put(%{"BINDIR" => nil})
      assert Inherited.get() == %{"BINDIR" => nil}
    end
  end

  describe "the processes started for a person" do
    test "a command finds the person's own programs, and none of the VM's variables", ctx do
      :ok = Inherited.put(%{"PATH" => ctx.person_path, @release_only => nil})
      command = "lmx-inherited-probe; printf 'release-only=%s\\n' \"${#{@release_only}-unset}\""

      for environment <- [Lemieux.Environment.local(), Local.new(credentials: {:scrub, []})] do
        assert {:ok, %{output: output, exit_status: 0}} =
                 Shell.run(environment, command, ctx.tmp_dir)

        assert output =~ "the person's own tool"
        assert output =~ "release-only=unset"
      end
    end

    test "without changes a command inherits the VM's environment, as before", ctx do
      :ok = Inherited.put(%{})
      command = "printf 'release-only=%s\\n' \"${#{@release_only}-unset}\""

      assert {:ok, %{output: output}} =
               Shell.run(Lemieux.Environment.local(), command, ctx.tmp_dir)

      assert output =~ "release-only=set for the VM"
    end

    test "a command hook's environment carries the same changes, its own variables first", ctx do
      :ok = Inherited.put(%{"PATH" => ctx.person_path, @release_only => nil})
      environment = Command.environment(%Command{command: "true"}, %{cwd: ctx.tmp_dir})

      assert {~c"PATH", to_charlist(ctx.person_path)} in environment
      assert {to_charlist(@release_only), false} in environment

      own = %Command{command: "true", env: %{"PATH" => "/the/hook/own"}}
      paths = for {~c"PATH", value} <- Command.environment(own, %{cwd: ctx.tmp_dir}), do: value
      assert paths == [~c"/the/hook/own"]
    end

    test "an MCP server's environment carries them, and it is found on the person's PATH",
         ctx do
      :ok = Inherited.put(%{"PATH" => ctx.person_path, @release_only => nil})
      environment = Stdio.port_env(%{}, :inherit)

      assert {~c"PATH", to_charlist(ctx.person_path)} in environment
      assert {to_charlist(@release_only), false} in environment
      assert Inherited.find_executable("lmx-inherited-probe") == ctx.tool

      configured = Stdio.port_env(%{"PATH" => "/the/server/own"}, :inherit)
      assert for({~c"PATH", value} <- configured, do: value) == [~c"/the/server/own"]
    end

    test "without changes a program is looked up on this VM's PATH" do
      :ok = Inherited.put(%{})
      assert Inherited.find_executable("lmx-inherited-probe") == nil
      assert Inherited.find_executable("sh") == System.find_executable("sh")
    end
  end
end
