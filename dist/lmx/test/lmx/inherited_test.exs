defmodule Lmx.InheritedTest do
  # The commands lmx starts get the environment the person started lmx with:
  # the launcher records it before it, the release script or erlexec changes
  # anything, and `Lmx.CLI.inherited/1` turns the VM's environment and those
  # records into the changes `Lemieux.Environment.Inherited` applies. Before,
  # the person's `erl` resolved to the release's ERTS ("cannot get bootfile")
  # and BINDIR, ROOTDIR, RELEASE_* and the launcher's own variables leaked
  # into every command.
  use ExUnit.Case, async: true

  # A person's shell, then what the launcher, the release script and erlexec
  # make of it for the VM.
  @person %{
    "PATH" => "/home/p/.local/bin:/usr/bin:/bin",
    "HOME" => "/home/p",
    "ERL_FLAGS" => "+S 2",
    "ERL_CRASH_DUMP" => "/home/p/dumps/erl_crash.dump",
    "RELEASE_COOKIE" => "the person's app cookie",
    "BINDIR" => "/usr/local/bin"
  }

  @root "/home/p/.lmx/install/current"
  @bindir @root <> "/erts-17.0.2/bin"

  defp vm(person, recorded) do
    person
    |> Map.merge(recorded)
    |> Map.merge(%{
      "PATH" => @bindir <> ":" <> @root <> "/bin:" <> person["PATH"],
      "BINDIR" => @bindir,
      "ROOTDIR" => @root,
      "EMU" => "beam",
      "PROGNAME" => "erl",
      "RELEASE_ROOT" => @root,
      "RELEASE_NAME" => "lmx",
      "RELEASE_DISTRIBUTION" => "none",
      "RELEASE_SYS_CONFIG" => @root <> "/releases/0.1.0/sys",
      "LMX_RELEASE_ROOT" => @root,
      "LMX_LAUNCHER_PID" => "4242",
      "LMX_LEASE_FILE" => "/home/p/.lmx/install/running/4242-x",
      "LMX_INSTALL_HOME" => "/home/p/.lmx/install"
    })
    |> Map.put_new("ERL_CRASH_DUMP", "/home/p/.lmx/crash/erl_crash.dump")
    |> Map.update("ELIXIR_ERL_OPTIONS", "+fnu", &("+fnu " <> &1))
  end

  # What the launcher records for `person`, as `LMX_PARENT_*`.
  defp records(person) do
    recorded =
      for {name, value} <- person,
          name in ~w(BINDIR ROOTDIR EMU PROGNAME ERL_CRASH_DUMP ELIXIR_ERL_OPTIONS) or
            String.starts_with?(name, "RELEASE_"),
          into: %{},
          do: {"LMX_PARENT__" <> name, value}

    Map.put(recorded, "LMX_PARENT_PATH", person["PATH"])
  end

  defp child(env, changes) do
    Enum.reduce(changes, env, fn
      {name, nil}, env -> Map.delete(env, name)
      {name, value}, env -> Map.put(env, name, value)
    end)
  end

  test "a command gets the person's environment back, and nothing lmx added" do
    vm = vm(@person, records(@person))
    child = child(vm, Lmx.CLI.inherited(vm))

    assert child == @person
  end

  test "what the person never set is removed, not restored to anything" do
    person = Map.drop(@person, ~w(ERL_CRASH_DUMP RELEASE_COOKIE BINDIR))
    vm = vm(person, records(person))
    child = child(vm, Lmx.CLI.inherited(vm))

    assert child == person
    refute Map.has_key?(child, "ERL_CRASH_DUMP")
    refute Map.has_key?(child, "RELEASE_DISTRIBUTION")
  end

  # The launcher puts +fnu in front of ELIXIR_ERL_OPTIONS for every VM the
  # release script starts; a person's command must not inherit that.
  test "ELIXIR_ERL_OPTIONS goes back to the person's value, or away" do
    person = Map.put(@person, "ELIXIR_ERL_OPTIONS", "+S 4")
    vm = vm(person, records(person))
    assert vm["ELIXIR_ERL_OPTIONS"] == "+fnu +S 4"
    assert child(vm, Lmx.CLI.inherited(vm))["ELIXIR_ERL_OPTIONS"] == "+S 4"

    vm = vm(@person, records(@person))
    assert vm["ELIXIR_ERL_OPTIONS"] == "+fnu"
    refute Map.has_key?(child(vm, Lmx.CLI.inherited(vm)), "ELIXIR_ERL_OPTIONS")
  end

  # A VM whose launcher recorded nothing: a hot upgrade gave an older
  # launcher's VM this code, or `bin/lmx-release` was run by hand. The PATH
  # here is erlexec's on Unix, `:`-separated; Windows separates with `;`.
  @tag :unix
  test "without the launcher's records, erlexec's own PATH entries come off its front" do
    person = Map.drop(@person, ~w(BINDIR ERL_CRASH_DUMP RELEASE_COOKIE))
    vm = vm(person, %{}) |> Map.delete("ERL_CRASH_DUMP")
    child = child(vm, Lmx.CLI.inherited(vm))

    assert child["PATH"] == person["PATH"]

    for name <- ~w(BINDIR ROOTDIR EMU PROGNAME RELEASE_ROOT RELEASE_NAME LMX_LAUNCHER_PID),
        do: refute(Map.has_key?(child, name), name)

    assert child["ERL_FLAGS"] == "+S 2"
  end

  test "a PATH erlexec did not put the release on is left alone" do
    vm = %{"PATH" => "/usr/bin:/bin", "BINDIR" => @bindir, "ROOTDIR" => @root}
    refute Map.has_key?(Lmx.CLI.inherited(vm), "PATH")
  end

  # The recording as the launcher ships it, run by a real shell: values with
  # quotes, `$`, backquotes and spaces come back as they were, and a value
  # holding a newline and something shaped like a name records nothing more.
  # The launcher is a POSIX shell script; Windows runs lmx.ps1 instead.
  @tag :unix
  test "the launcher records the person's values exactly as they were" do
    script = File.read!(Application.app_dir(:lmx, "priv/launcher.sh"))
    [_before, rest] = String.split(script, ~s|if [ "${PATH+set}" = set ]|, parts: 2)
    [block, _after] = String.split(rest, "\ndone\n", parts: 2)
    recording = ~s|if [ "${PATH+set}" = set ]| <> block <> "\ndone\nenv -0 2>/dev/null || env\n"

    person = %{
      "PATH" => "/opt/person/bin:/usr/bin:/bin",
      "BINDIR" => ~S(a "quoted" $value `with` spaces),
      "RELEASE_COOKIE" => "cookie",
      "RELEASE_NOTES" => "one\nRELEASE_FORGED$(touch /nonexistent)=x"
    }

    {output, 0} =
      System.cmd(
        "env",
        ["-i"] ++
          Enum.map(person, fn {name, value} -> "#{name}=#{value}" end) ++
          ["/bin/sh", "-c", recording]
      )

    recorded = parse(output)

    assert recorded["LMX_PARENT_PATH"] == person["PATH"]
    assert recorded["LMX_PARENT__BINDIR"] == person["BINDIR"]
    assert recorded["LMX_PARENT__RELEASE_COOKIE"] == "cookie"
    assert recorded["LMX_PARENT__RELEASE_NOTES"] == person["RELEASE_NOTES"]
    refute Map.has_key?(recorded, "LMX_PARENT__RELEASE_FORGED")
    refute Map.has_key?(recorded, "LMX_PARENT__ROOTDIR")

    child = child(vm(person, recorded), Lmx.CLI.inherited(vm(person, recorded)))
    assert Map.take(child, Map.keys(person)) == person
  end

  # `env -0` where the system has it; one variable per line otherwise, which
  # the values above survive except the one with a newline.
  defp parse(output) do
    separator = if String.contains?(output, <<0>>), do: <<0>>, else: "\n"

    output
    |> String.split(separator, trim: true)
    |> Enum.flat_map(fn entry ->
      case String.split(entry, "=", parts: 2) do
        [name, value] -> [{name, value}]
        _continuation -> []
      end
    end)
    |> Map.new()
  end
end
