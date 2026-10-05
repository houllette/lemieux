defmodule VerifierExtension.Discovery do
  @moduledoc """
  Finds the repository's own verification command from its conventions.

  The command is discovered, not asked for: the point of the pipeline is that
  the check runs whether or not the model thought to run it, so the source of
  the command has to be something the model cannot skip. Conventions are
  tried in a fixed order and the first match wins:

    1. an explicit `:verify_command` option supplied by the host;
    2. `tests/run.sh`, run with `sh`;
    3. a `Makefile` with a `test` target, then one with a `check` target;
    4. `mix.exs`, meaning `mix test`;
    5. `package.json` with a real `scripts.test` entry, meaning `npm test`.

  `check.sh` is deliberately absent from that list. In this repository's
  discovery corpus it is the external grader, and a verifier that ran it
  would be reading the answer key: every pass rate it produced would measure
  how well the agent satisfied the grader it was shown rather than whether it
  verified its own work. The corpus prompts never mention the file, and this
  module never proposes it, so the only check the pipeline can run is the one
  the project's own conventions name. A host that genuinely uses a `check.sh`
  as its test entry point passes it as `:verify_command`.

  Discovery reads the workspace directly rather than through the session
  environment: it looks at file names and a few bytes of a `Makefile` or
  `package.json`, and a workspace the loop's file tools cannot see is not one
  the model could have verified either.
  """

  @typedoc "A verification command and the convention that produced it."
  @type discovery :: %{command: String.t(), discovered_from: String.t()}

  @conventions [
    {"tests/run.sh", :run_script},
    {"Makefile", :makefile},
    {"mix.exs", :mix},
    {"package.json", :package_json}
  ]

  @doc """
  Discovers the verification command for `cwd`.

  Returns `:none` when no convention matches; the pipeline then reports
  `discovered_from: nil` and runs no check rather than guessing.
  """
  @spec discover(cwd :: Path.t(), opts :: keyword()) :: {:ok, discovery()} | :none
  def discover(cwd, opts \\ []) when is_binary(cwd) and is_list(opts) do
    case Keyword.get(opts, :verify_command) do
      command when is_binary(command) and command != "" ->
        {:ok, %{command: command, discovered_from: "verify_command"}}

      _absent ->
        Enum.find_value(@conventions, :none, fn {file, kind} ->
          convention(kind, Path.join(cwd, file), file)
        end)
    end
  end

  defp convention(:run_script, path, file) do
    if File.regular?(path), do: {:ok, %{command: "sh #{file}", discovered_from: file}}
  end

  defp convention(:makefile, path, file) do
    with {:ok, contents} <- File.read(path),
         {:ok, target} <- make_target(contents) do
      {:ok, %{command: "make #{target}", discovered_from: file}}
    else
      _no_target -> nil
    end
  end

  defp convention(:mix, path, file) do
    if File.regular?(path), do: {:ok, %{command: "mix test", discovered_from: file}}
  end

  defp convention(:package_json, path, file) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"scripts" => %{"test" => script}}} when is_binary(script) <-
           JSON.decode(contents),
         true <- real_test_script?(script) do
      {:ok, %{command: "npm test", discovered_from: file}}
    else
      _no_script -> nil
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
  # Treating it as a suite would fail every run and burn the retry on nothing.
  defp real_test_script?(script),
    do: String.trim(script) != "" and not String.contains?(script, "no test specified")
end
