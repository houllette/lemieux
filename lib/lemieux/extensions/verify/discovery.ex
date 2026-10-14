defmodule Lemieux.Extensions.Verify.Discovery do
  @moduledoc """
  Finds a repository's own verification command from its conventions.

  The command is discovered, not asked for: the point of verifying is that
  the check runs whether or not the model thought to run it, so the source of
  the command has to be something the model cannot skip. Conventions are
  tried in a fixed order and the first match wins:

    1. an explicit `:command` supplied by the host;
    2. `tests/run.sh`, run with `sh`;
    3. a `Makefile` with a `test` target, then one with a `check` target;
    4. `mix.exs`, meaning `mix test`;
    5. `package.json` with a real `scripts.test`, run with the package
       manager its lockfile names (`pnpm`, `yarn`, `bun`, else `npm`);
    6. `Cargo.toml`, meaning `cargo test`;
    7. `go.mod`, meaning `go test ./...`;
    8. pytest configuration (`pytest.ini`, a `[tool.pytest` table in
       `pyproject.toml`, `[tool:pytest]` in `setup.cfg`, `[pytest]` in
       `tox.ini`, or a root `conftest.py`), meaning `pytest -q`;
    9. a Gradle wrapper, meaning `./gradlew test`, then `pom.xml`, meaning
       `mvn -q test`.

  The project's own entry point comes first on purpose: a `Makefile` target
  or a `tests/run.sh` is what its authors said "the tests" are, and it may
  set up what a bare `mix test` or `npm test` would miss.

  `check.sh` is deliberately absent. In this repository's discovery corpus it
  is the external grader, and a verifier that ran it would be reading the
  answer key. A host whose project genuinely uses one passes it as
  `:command`.

  Discovery reads through the effective `Lemieux.Environment`, the same
  boundary that runs the check. `:environment` defaults to the local machine
  for standalone callers; a custom environment never falls back to host files.
  Manifest parsing stops at 64 KiB. A host may always supply `:command` when
  its convention is absent or a manifest exceeds that bound.
  """

  alias Lemieux.Environment
  alias Lemieux.Environment.Local

  @max_manifest_bytes 65_536

  @typedoc "A verification command and the convention that produced it."
  @type discovery :: %{command: String.t(), discovered_from: String.t()}

  @conventions [
    :run_script,
    :makefile,
    :mix,
    :package_json,
    :cargo,
    :go,
    :pytest,
    :gradle,
    :maven
  ]

  @doc """
  Discovers the verification command for `cwd`.

  Options: `:command` and `:environment`. Returns `:none` when no readable
  convention matches; nothing is guessed.
  """
  @spec discover(cwd :: Path.t(), opts :: keyword()) :: {:ok, discovery()} | :none
  def discover(cwd, opts \\ []) when is_binary(cwd) and is_list(opts) do
    case Keyword.get(opts, :command) do
      command when is_binary(command) and command != "" ->
        {:ok, %{command: command, discovered_from: "command"}}

      _absent ->
        workspace = {Keyword.get(opts, :environment, Environment.local()), cwd}
        Enum.find_value(@conventions, :none, &convention(&1, workspace))
    end
  end

  defp convention(:run_script, cwd) do
    if present?(cwd, "tests/run.sh"),
      do: found("sh tests/run.sh", "tests/run.sh")
  end

  defp convention(:makefile, cwd) do
    with {:ok, contents} <- read(cwd, "Makefile"),
         {:ok, target} <- make_target(contents) do
      found("make #{target}", "Makefile")
    else
      _no_target -> nil
    end
  end

  defp convention(:mix, cwd) do
    if present?(cwd, "mix.exs"), do: found("mix test", "mix.exs")
  end

  defp convention(:package_json, cwd) do
    with {:ok, contents} <- read(cwd, "package.json"),
         {:ok, %{"scripts" => %{"test" => script}}} when is_binary(script) <-
           JSON.decode(contents),
         true <- real_test_script?(script) do
      found(package_manager(cwd), "package.json")
    else
      _no_script -> nil
    end
  end

  defp convention(:cargo, cwd) do
    if present?(cwd, "Cargo.toml"), do: found("cargo test", "Cargo.toml")
  end

  defp convention(:go, cwd) do
    if present?(cwd, "go.mod"), do: found("go test ./...", "go.mod")
  end

  defp convention(:pytest, cwd) do
    Enum.find_value(
      [
        {"pytest.ini", nil},
        {"pyproject.toml", "[tool.pytest"},
        {"setup.cfg", "[tool:pytest]"},
        {"tox.ini", "[pytest]"},
        {"conftest.py", nil}
      ],
      fn {file, marker} ->
        if configures_pytest?(cwd, file, marker), do: found("pytest -q", file)
      end
    )
  end

  defp convention(:gradle, cwd) do
    if present?(cwd, "gradlew"), do: found("./gradlew test", "gradlew")
  end

  defp convention(:maven, cwd) do
    if present?(cwd, "pom.xml"), do: found("mvn -q test", "pom.xml")
  end

  defp found(command, file), do: {:ok, %{command: command, discovered_from: file}}

  defp configures_pytest?(workspace, path, nil), do: present?(workspace, path)

  defp configures_pytest?(workspace, path, marker) do
    case read(workspace, path) do
      {:ok, contents} -> String.contains?(contents, marker)
      {:error, _reason} -> false
    end
  end

  defp present?({environment, cwd}, path) do
    if local_regular?(environment, cwd, path) do
      probe(environment, cwd, path)
    else
      false
    end
  end

  # A local existence probe must not open a FIFO or device: the old regular?
  # check rejected those before any I/O. Custom backends own their file kinds.
  defp local_regular?(environment, cwd, path) do
    if Environment.name(environment) in [
         "Lemieux.Environment.Local",
         "Lemieux.Environment.Sandbox"
       ] do
      case Local.confined(cwd, path) do
        {:ok, full} -> File.regular?(full)
        _refused -> false
      end
    else
      true
    end
  end

  defp probe(environment, cwd, path) do
    case Environment.stream_file(environment, cwd, path) do
      {:ok, stream} ->
        # stream_file may already own a device or remote lease. Taking one
        # chunk exercises and closes it even when only existence matters.
        _first_chunk = Enum.take(stream, 1)
        true

      {:error, _reason} ->
        false
    end
  end

  defp read({environment, cwd}, path) do
    with {:ok, chunks} <- Environment.stream_file(environment, cwd, path) do
      chunks
      |> Enum.reduce_while({[], 0}, &manifest_chunk/2)
      |> case do
        :too_large -> {:error, :too_large}
        {kept, _size} -> {:ok, kept |> Enum.reverse() |> IO.iodata_to_binary()}
      end
    end
  end

  defp manifest_chunk(chunk, {kept, size}) do
    if size + byte_size(chunk) <= @max_manifest_bytes,
      do: {:cont, {[chunk | kept], size + byte_size(chunk)}},
      else: {:halt, :too_large}
  end

  # A target line starts the line, so `testdata:` and `.PHONY: test` do not
  # count; `test:` and `check: build` do. `test` wins over `check` when a
  # Makefile has both because it is the narrower promise.
  defp make_target(contents) do
    Enum.find_value(["test", "check"], {:error, :no_target}, fn target ->
      if Regex.match?(~r/^#{target}[ \t]*::?(?!=)/m, contents), do: {:ok, target}
    end)
  end

  # `npm init` writes a test script that only prints an error and exits 1.
  # Treating it as a suite would fail every run and spend the continuation
  # on nothing.
  defp real_test_script?(script),
    do: String.trim(script) != "" and not String.contains?(script, "no test specified")

  # The lockfile says which manager installed the tree; running another one
  # can resolve a different dependency graph than the one on disk.
  defp package_manager(cwd) do
    cond do
      present?(cwd, "pnpm-lock.yaml") -> "pnpm test"
      present?(cwd, "yarn.lock") -> "yarn test"
      present?(cwd, "bun.lockb") -> "bun run test"
      present?(cwd, "bun.lock") -> "bun run test"
      true -> "npm test"
    end
  end
end
