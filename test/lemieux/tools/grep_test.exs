defmodule Lemieux.Tools.GrepTest do
  use ExUnit.Case, async: true

  alias Lemieux.Environment.Local
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.Grep

  @moduletag :tmp_dir

  # The local machine with some programs taken away, so each fallback backend
  # can be exercised on any machine: the shell's "command not found" is status
  # 127, which is exactly what the search tools read as "not available here".
  defmodule Without do
    @moduledoc false
    @behaviour Lemieux.Environment

    def read_file(_programs, cwd, path), do: Local.read_file(nil, cwd, path)
    def list_dir(_programs, cwd, path), do: Local.list_dir(nil, cwd, path)
    def write_file(_programs, cwd, path, contents), do: Local.write_file(nil, cwd, path, contents)

    def run(programs, command, opts) do
      program = command |> String.trim_leading("'") |> String.split(["'", " "], parts: 2) |> hd()

      if program in programs,
        do: {:ok, [{:data, "sh: #{program}: command not found\n"}, {:exit_status, 127}]},
        else: Local.run(nil, command, opts)
    end
  end

  setup %{tmp_dir: tmp_dir} do
    write(tmp_dir, "lib/a.ex", """
    defmodule A do
      def foo, do: :ok

      def bar, do: foo()
    end
    """)

    write(tmp_dir, "lib/sub/b.ex", "defmodule B do\n  def foo_b, do: A.foo()\nend\n")
    write(tmp_dir, "test/a_test.exs", "defmodule ATest do\n  test \"foo\", do: A.foo()\nend\n")
    write(tmp_dir, ".gitignore", "ignored/\n")
    write(tmp_dir, "ignored/c.ex", "def foo, do: :hidden\n")

    %{ctx: context(tmp_dir, Lemieux.Environment.local())}
  end

  defp context(tmp_dir, environment),
    do: %{cwd: tmp_dir, session_id: "s1", call_id: "c1", environment: environment}

  defp write(tmp_dir, name, contents) do
    path = Path.join(tmp_dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp grep(args, ctx) do
    case Grep.run(args, ctx) do
      {:ok, %Result{} = result} -> {:ok, result.model_text, result.metadata}
      {:error, message} -> {:error, message}
    end
  end

  defp git_init(tmp_dir), do: {_, 0} = System.cmd("git", ["init", "-q"], cd: tmp_dir)

  # Every backend a search can end up on, so the tests below hold whichever one
  # a machine offers. `rg` is only listed where it is installed.
  defp backends(tmp_dir) do
    rg = if System.find_executable("rg"), do: [rg: Lemieux.Environment.local()], else: []
    git_init(tmp_dir)

    rg ++
      [
        git: {Without, ["rg"]},
        walk: {Without, ["rg", "git"]}
      ]
  end

  test "returns matching lines as path:line:text with a count", %{ctx: ctx} do
    assert {:ok, text, metadata} = grep(%{"pattern" => "def foo,"}, ctx)

    assert text == """
           lib/a.ex:2:  def foo, do: :ok

           [1 matching line in 1 file]\
           """

    assert metadata["matches"] == 1
    assert metadata["truncated"] == false
  end

  test "every backend gives the same answer and honours .gitignore", %{tmp_dir: tmp_dir} do
    answers =
      for {name, environment} <- backends(tmp_dir) do
        {:ok, text, metadata} = grep(%{"pattern" => "foo"}, context(tmp_dir, environment))
        assert metadata["backend"] == Atom.to_string(name)
        text
      end

    assert [first | rest] = answers
    assert Enum.all?(rest, &(&1 == first)), inspect(answers, pretty: true)
    refute first =~ "ignored/c.ex"
    assert first =~ "lib/sub/b.ex:2:  def foo_b, do: A.foo()"
    assert first =~ "test/a_test.exs:2:"
  end

  test "every mode agrees across backends", %{tmp_dir: tmp_dir} do
    write(tmp_dir, "long.txt", Enum.map_join(1..20, "\n", &"line #{&1}") <> "\n")

    queries = [
      %{"pattern" => "foo", "output_mode" => "files_with_matches"},
      %{"pattern" => "foo", "output_mode" => "count"},
      %{"pattern" => "def", "glob" => "lib/**/*.ex", "context" => 1},
      %{"pattern" => "^line 1[0-9]$", "max_results" => 3},
      %{"pattern" => "LINE 2", "case_insensitive" => true, "context" => 2}
    ]

    environments = backends(tmp_dir)

    for query <- queries do
      answers =
        for {_name, environment} <- environments do
          {:ok, text, _metadata} = grep(query, context(tmp_dir, environment))
          text
        end

      assert Enum.uniq(answers) |> length() == 1,
             "#{inspect(query)} differs: #{inspect(answers, pretty: true)}"
    end
  end

  test "files_with_matches lists paths and count gives matching lines per file", %{ctx: ctx} do
    assert {:ok, text, _metadata} =
             grep(%{"pattern" => "foo", "output_mode" => "files_with_matches"}, ctx)

    assert text == "lib/a.ex\nlib/sub/b.ex\ntest/a_test.exs\n\n[3 files]"

    assert {:ok, text, _metadata} = grep(%{"pattern" => "foo", "output_mode" => "count"}, ctx)
    assert text =~ "lib/a.ex:2\nlib/sub/b.ex:1\ntest/a_test.exs:1"
    assert text =~ "[4 matching lines in 3 files]"
  end

  test "context lines are marked with - and separated groups with --", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    write(tmp_dir, "long.txt", Enum.map_join(1..20, "\n", &"line #{&1}") <> "\n")

    assert {:ok, text, _metadata} =
             grep(%{"pattern" => "^line (3|15)$", "path" => "long.txt", "context" => 1}, ctx)

    assert text =~ """
           long.txt-2-line 2
           long.txt:3:line 3
           long.txt-4-line 4
           --
           long.txt-14-line 14
           long.txt:15:line 15
           long.txt-16-line 16
           """
  end

  test "a capped search says there are more", %{tmp_dir: tmp_dir, ctx: ctx} do
    write(tmp_dir, "many.txt", Enum.map_join(1..50, "\n", &"hit #{&1}") <> "\n")

    assert {:ok, text, metadata} =
             grep(%{"pattern" => "hit", "path" => "many.txt", "max_results" => 5}, ctx)

    assert text =~ "many.txt:5:hit 5"
    refute text =~ "many.txt:6:"
    assert text =~ "[showing 5 matching lines in 1 file; there are more."
    assert metadata["truncated"] == true
  end

  test "a glob narrows the files searched", %{ctx: ctx} do
    assert {:ok, text, _metadata} = grep(%{"pattern" => "foo", "glob" => "*.exs"}, ctx)
    assert text =~ "test/a_test.exs:2:"
    refute text =~ "lib/"

    assert {:ok, text, _metadata} =
             grep(%{"pattern" => "foo", "path" => "lib", "glob" => "sub/*.ex"}, ctx)

    assert text =~ "lib/sub/b.ex:2:"
    refute text =~ "lib/a.ex"
  end

  test "literal and case-insensitive searches", %{tmp_dir: tmp_dir, ctx: ctx} do
    write(tmp_dir, "sym.txt", "a.b(c)\naxb(c)\nHELLO\n")

    assert {:ok, text, _metadata} =
             grep(%{"pattern" => "a.b(c)", "path" => "sym.txt", "literal" => true}, ctx)

    assert text =~ "sym.txt:1:a.b(c)"
    refute text =~ "axb"

    assert {:ok, text, _metadata} =
             grep(%{"pattern" => "hello", "path" => "sym.txt", "case_insensitive" => true}, ctx)

    assert text =~ "sym.txt:3:HELLO"
    assert {:ok, text, _metadata} = grep(%{"pattern" => "hello", "path" => "sym.txt"}, ctx)
    assert text =~ "No matches"
  end

  test "a pattern that starts with a dash is a pattern, not an option", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    write(tmp_dir, "dash.txt", "--verbose flag\n")

    assert {:ok, text, _metadata} = grep(%{"pattern" => "--verbose", "path" => "dash.txt"}, ctx)
    assert text =~ "dash.txt:1:--verbose flag"
  end

  test "a pattern cannot reach the shell", %{tmp_dir: tmp_dir} do
    for {_name, environment} <- backends(tmp_dir) do
      ctx = context(tmp_dir, environment)
      grep(%{"pattern" => "x'; touch pwned; echo '"}, ctx)
      grep(%{"pattern" => "x", "glob" => "*'; touch pwned2; echo '"}, ctx)
    end

    refute File.exists?(Path.join(tmp_dir, "pwned"))
    refute File.exists?(Path.join(tmp_dir, "pwned2"))
  end

  test "an invalid regular expression is reported, whichever backend ran", %{tmp_dir: tmp_dir} do
    for {name, environment} <- backends(tmp_dir) do
      assert {:error, message} = grep(%{"pattern" => "foo("}, context(tmp_dir, environment))
      assert message =~ "grep:", "#{name}: #{message}"
    end
  end

  test "binary files are skipped", %{tmp_dir: tmp_dir} do
    write(tmp_dir, "blob.bin", "foo" <> <<0, 1, 2>> <> "foo")

    for {name, environment} <- backends(tmp_dir) do
      {:ok, text, _metadata} = grep(%{"pattern" => "foo"}, context(tmp_dir, environment))
      refute text =~ "blob.bin", "#{name} searched a binary file"
    end
  end

  test "very long lines are cut and say so", %{tmp_dir: tmp_dir, ctx: ctx} do
    write(tmp_dir, "min.js", "var x = '" <> String.duplicate("a", 5_000) <> "';\n")

    assert {:ok, text, _metadata} = grep(%{"pattern" => "var x", "path" => "min.js"}, ctx)
    assert text =~ "[line truncated]"
    assert byte_size(text) < 1_000
  end

  test "a named file is searched even when ignored", %{ctx: ctx} do
    assert {:ok, text, _metadata} = grep(%{"pattern" => "hidden", "path" => "ignored/c.ex"}, ctx)
    assert text =~ "ignored/c.ex:1:def foo, do: :hidden"
  end

  test "paths outside the working directory and missing paths are errors", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    assert {:error, message} = grep(%{"pattern" => "x", "path" => "../"}, ctx)
    assert message =~ "outside the working directory"

    assert {:error, message} = grep(%{"pattern" => "x", "path" => "/etc"}, ctx)
    assert message =~ "outside the working directory"

    assert {:error, message} = grep(%{"pattern" => "x", "path" => "nope"}, ctx)
    assert message =~ "no such file or directory"

    # An absolute path that names something inside the project is fine.
    assert {:ok, text, _metadata} =
             grep(%{"pattern" => "foo_b", "path" => Path.join(tmp_dir, "lib")}, ctx)

    assert text =~ "lib/sub/b.ex:2:"
  end

  test "a search with no pattern is refused before anything runs", %{ctx: ctx} do
    assert {:error, _message} = Grep.run(%{"pattern" => ""}, ctx)
    assert {:error, _message} = Grep.run(%{}, ctx)
    assert {:error, message} = Grep.run(%{"pattern" => "x", "output_mode" => "lines"}, ctx)
    assert message =~ "output_mode"
  end

  test "is read-only and parallel-safe, so a scout may carry it" do
    assert Lemieux.Tool.read_only?(Grep)
    assert Lemieux.Tool.parallel_safe?(Grep)
    assert :ok = Lemieux.Tool.validate_all([Grep])
  end
end
