defmodule Lemieux.CLI.ShellQuotedTest do
  # The lines a hint asks a person to paste are quoted by one helper,
  # `Lemieux.CLI.shell_quoted/1`. The terminal UI kept a copy anchored with
  # `^`/`$`, which also match before a final newline, so an argument ending
  # in one was printed bare in its stray-prompt and resume hints, and the
  # pasted line ran as two commands.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.TUI
  alias Lemieux.Entry
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  describe "shell_quoted/1" do
    test "leaves a word no shell treats specially bare" do
      assert CLI.shell_quoted("src/lib-1.2_x@host:9,a=b+c%") == "src/lib-1.2_x@host:9,a=b+c%"
    end

    test "quotes a word that ends in a newline" do
      assert CLI.shell_quoted("fix\n") == "'fix\n'"
    end

    test "quotes what a shell would expand or split, and an empty word" do
      assert CLI.shell_quoted("$HOME") == "'$HOME'"
      assert CLI.shell_quoted("a b") == "'a b'"
      assert CLI.shell_quoted("") == "''"
      assert CLI.shell_quoted("it's") == ~S('it'\''s')
    end

    # zsh, the macOS default shell, expands a word starting with `=` to the
    # path of the command it names: `=foo` ran as "foo not found".
    test "quotes a word that starts with =, and only then" do
      assert CLI.shell_quoted("=foo") == "'=foo'"
      assert CLI.shell_quoted("=") == "'='"
      assert CLI.shell_quoted("--model=x") == "--model=x"
    end

    # What the line is for: pasted into the shell, each argument comes back
    # as it was. zsh where there is one, since it is the one expanding `=`.
    if match?({:win32, _}, :os.type()), do: @tag(skip: "the hints are for a POSIX shell")

    test "a quoted line reads back as the arguments it was made from" do
      shell = System.find_executable("zsh") || System.find_executable("sh")
      arguments = ["=foo", "it's", "a b", "fix\n", "$HOME", "--model=x", ""]
      line = Enum.map_join(arguments, " ", &CLI.shell_quoted/1)

      {output, 0} = System.cmd(shell, ["-c", "printf '%s\\0' " <> line])

      assert String.split(output, <<0>>) == arguments ++ [""]
    end
  end

  test "the terminal UI's stray-prompt line quotes an argument ending in a newline" do
    stderr =
      capture_io(:stderr, fn ->
        assert {:error, 1} = TUI.main(["fix\n", "--config", "none"], program: "mix lmx")
      end)

    assert stderr =~ "mix lmx run 'fix\n' --config none"
  end

  test "the resume hint quotes a directory whose name ends in a newline", %{tmp_dir: dir} do
    project = Path.join(dir, "project\n")
    File.mkdir_p!(project)
    store = JSONL.new(Path.join(dir, "sessions"))

    :ok =
      Store.append(store, Lemieux.ID.generate(), [
        Entry.new(:session, %{"model" => "test:model", "cwd" => project, "tools" => []}),
        Entry.new(:user, %{"text" => "what does this do?"}),
        Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "it reads"}]})
      ])

    assert TUI.resume_hint(store, project, []) =~ "`lmx -C '#{project}' -c` resumes it"
  end
end
