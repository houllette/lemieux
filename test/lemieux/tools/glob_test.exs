defmodule Lemieux.Tools.GlobTest do
  use ExUnit.Case, async: true

  alias Lemieux.Environment.Local
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.Glob

  @moduletag :tmp_dir

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
    for name <- [
          "mix.exs",
          "lib/a.ex",
          "lib/sub/b.ex",
          "test/a_test.exs",
          ".github/workflows/ci.yml",
          "node_modules/pkg/index.js",
          "build/out.ex"
        ] do
      path = Path.join(tmp_dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "x\n")
    end

    File.write!(Path.join(tmp_dir, ".gitignore"), "build/\nnode_modules/\n")
    %{ctx: context(tmp_dir, Lemieux.Environment.local())}
  end

  defp context(tmp_dir, environment),
    do: %{cwd: tmp_dir, session_id: "s1", call_id: "c1", environment: environment}

  defp glob(args, ctx) do
    case Glob.run(args, ctx) do
      {:ok, %Result{} = result} -> {:ok, result.model_text}
      {:error, message} -> {:error, message}
    end
  end

  defp backends(tmp_dir) do
    {_, 0} = System.cmd("git", ["init", "-q"], cd: tmp_dir)
    rg = if System.find_executable("rg"), do: [Lemieux.Environment.local()], else: []
    rg ++ [{Without, ["rg"]}, {Without, ["rg", "git"]}]
  end

  test "a pattern without a slash finds names at any depth, sorted", %{ctx: ctx} do
    assert {:ok, text} = glob(%{"pattern" => "*.ex"}, ctx)
    assert text == "lib/a.ex\nlib/sub/b.ex\n\n[2 files]"
  end

  test "a pattern with a slash is anchored at path", %{ctx: ctx} do
    assert {:ok, "lib/a.ex\n\n[1 file]"} = glob(%{"pattern" => "lib/*.ex"}, ctx)

    assert {:ok, "lib/sub/b.ex\n\n[1 file]"} =
             glob(%{"pattern" => "sub/*.ex", "path" => "lib"}, ctx)

    assert {:ok, text} = glob(%{"pattern" => "**/*.{ex,exs}"}, ctx)
    assert text == "lib/a.ex\nlib/sub/b.ex\nmix.exs\ntest/a_test.exs\n\n[4 files]"
  end

  test "dotfiles are found and ignored directories are not, on every backend", %{
    tmp_dir: tmp_dir
  } do
    answers =
      for environment <- backends(tmp_dir) do
        {:ok, text} = glob(%{"pattern" => "*"}, context(tmp_dir, environment))
        text
      end

    assert [first | _rest] = answers
    assert Enum.uniq(answers) == [first], inspect(answers, pretty: true)
    assert first =~ ".github/workflows/ci.yml"
    refute first =~ "node_modules"
    refute first =~ "build/out.ex"
  end

  test "a capped listing says how many there were", %{ctx: ctx} do
    assert {:ok, text} = glob(%{"pattern" => "*", "max_results" => 2}, ctx)
    assert text =~ "[showing 2 of"
    assert length(String.split(text, "\n")) == 4
  end

  test "no match, a file as path and escaping paths are reported", %{ctx: ctx} do
    assert {:ok, "No files match \"*.rs\" in the working directory."} =
             glob(%{"pattern" => "*.rs"}, ctx)

    assert {:ok, "No files match \"*.rs\" in lib."} =
             glob(%{"pattern" => "*.rs", "path" => "lib"}, ctx)

    assert {:error, message} = glob(%{"pattern" => "*", "path" => "mix.exs"}, ctx)
    assert message =~ "is a file"
    assert {:error, message} = glob(%{"pattern" => "*", "path" => ".."}, ctx)
    assert message =~ "outside the working directory"
  end

  test "is read-only and parallel-safe" do
    assert Lemieux.Tool.read_only?(Glob)
    assert Lemieux.Tool.parallel_safe?(Glob)
    assert :ok = Lemieux.Tool.validate_all([Glob])
  end
end
