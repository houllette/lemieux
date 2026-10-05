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

  Discovery reads a few file names and a few bytes of manifests on the
  session's machine. A host that runs tools in a container or on a remote
  workspace should pass `:command`, since the files the model edits are
  then somewhere else.
  """

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

  Returns `:none` when no convention matches; nothing is guessed.
  """
  @spec discover(cwd :: Path.t(), opts :: keyword()) :: {:ok, discovery()} | :none
  def discover(cwd, opts \\ []) when is_binary(cwd) and is_list(opts) do
    case Keyword.get(opts, :command) do
      command when is_binary(command) and command != "" ->
        {:ok, %{command: command, discovered_from: "command"}}

      _absent ->
        Enum.find_value(@conventions, :none, &convention(&1, cwd))
    end
  end

  defp convention(:run_script, cwd) do
    if File.regular?(Path.join(cwd, "tests/run.sh")),
      do: found("sh tests/run.sh", "tests/run.sh")
  end

  defp convention(:makefile, cwd) do
    with {:ok, contents} <- File.read(Path.join(cwd, "Makefile")),
         {:ok, target} <- make_target(contents) do
      found("make #{target}", "Makefile")
    else
      _no_target -> nil
    end
  end

  defp convention(:mix, cwd) do
    if File.regular?(Path.join(cwd, "mix.exs")), do: found("mix test", "mix.exs")
  end

  defp convention(:package_json, cwd) do
    with {:ok, contents} <- File.read(Path.join(cwd, "package.json")),
         {:ok, %{"scripts" => %{"test" => script}}} when is_binary(script) <-
           JSON.decode(contents),
         true <- real_test_script?(script) do
      found(package_manager(cwd), "package.json")
    else
      _no_script -> nil
    end
  end

  defp convention(:cargo, cwd) do
    if File.regular?(Path.join(cwd, "Cargo.toml")), do: found("cargo test", "Cargo.toml")
  end

  defp convention(:go, cwd) do
    if File.regular?(Path.join(cwd, "go.mod")), do: found("go test ./...", "go.mod")
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
        if configures_pytest?(Path.join(cwd, file), marker), do: found("pytest -q", file)
      end
    )
  end

  defp convention(:gradle, cwd) do
    if File.regular?(Path.join(cwd, "gradlew")), do: found("./gradlew test", "gradlew")
  end

  defp convention(:maven, cwd) do
    if File.regular?(Path.join(cwd, "pom.xml")), do: found("mvn -q test", "pom.xml")
  end

  defp found(command, file), do: {:ok, %{command: command, discovered_from: file}}

  defp configures_pytest?(path, nil), do: File.regular?(path)

  defp configures_pytest?(path, marker) do
    case File.read(path) do
      {:ok, contents} -> String.contains?(contents, marker)
      {:error, _reason} -> false
    end
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
      File.regular?(Path.join(cwd, "pnpm-lock.yaml")) -> "pnpm test"
      File.regular?(Path.join(cwd, "yarn.lock")) -> "yarn test"
      File.regular?(Path.join(cwd, "bun.lockb")) -> "bun run test"
      File.regular?(Path.join(cwd, "bun.lock")) -> "bun run test"
      true -> "npm test"
    end
  end
end
