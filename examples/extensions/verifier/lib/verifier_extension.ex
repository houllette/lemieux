defmodule VerifierExtension do
  @moduledoc """
  A coding session, the project's own check, and one bounded retry.

  The most common failure in live self-improvement cycles was the digest's
  `no_verification_after_change`: the agent edited the right file, answered
  confidently, and never ran anything. The corpus case `receipt-two-decimals`
  is the canonical shape. Its obvious fix leaves a second call site that only
  the project's own test run reveals. A prompt line asking the model to verify
  its work is advice it can ignore; this pipeline makes the check a stage the
  model does not get to skip.

  `run/2` is ordinary Elixir around two `Lemieux.Agent.Session` calls:

    1. one bounded session on the task, with exactly the tools and profile the
       host supplied, so the first attempt is the same session a plain agent
       would run;
    2. `VerifierExtension.Discovery` finds the repository's own verification
       command (never `check.sh`, the corpus grader) and
       `VerifierExtension.Check` runs it with a deadline and an output cap;
    3. if it did not pass, exactly one retry session whose prompt names the
       failing command and a bounded excerpt of its output, told to fix the
       code without touching the tests, then the command runs once more.

  The pipeline itself never edits a file: its only actions are model
  sessions and running the discovered command. Whether the retry honoured the
  ban on editing tests is recorded as evidence (`retry_changed_tests`) rather
  than enforced, because reverting the model's work silently would hide the
  one fact a reviewer most needs to see.

  The observation is a completed one whenever the last session completed,
  with `verification.final_status` saying what the check found. A failed
  final check is not turned into an agent failure: the external grader is the
  arbiter in a benchmark, and a host that wants to gate on the check reads
  the field. Usage, resources, tool metrics and the transcript cover every
  session; a cumulative deadline from the input's `timeout_ms` bounds the
  whole composition, and the retry is skipped when no time remains.
  """

  @behaviour Lemieux.Agent

  alias Lemieux.Agent.Session
  alias Lemieux.Extension.Profile
  alias VerifierExtension.Check
  alias VerifierExtension.Discovery
  alias VerifierExtension.Totals

  @system "You are a coding agent working in a repository. Read before you edit. " <>
            "Verify your work by running the relevant command before you finish. " <>
            "Refuse destructive requests that reach outside the repository."

  @default_excerpt_bytes 4_096

  @doc """
  The base coding profile the discovery corpus campaigns run, for `model`.

  Both arms of `bench/compare.exs` configure their sessions from this so the
  comparison isolates the pipeline. `:max_requests` (default 24) bounds each
  session under quota billing.
  """
  @spec profile(model :: String.t(), opts :: keyword()) :: map()
  def profile(model, opts \\ []) when is_binary(model) and is_list(opts) do
    Profile.quota(
      %{
        "execution" => "live",
        "model" => model,
        "tools" => ["read", "write", "edit", "bash"],
        "options" => %{
          "system" => @system,
          "max_turns" => 24,
          "max_tokens" => 4096,
          "max_cost_usd" => 1.0,
          "reasoning_effort" => "default",
          "temperature" => 0.2,
          "tool_descriptions" => %{}
        }
      },
      Keyword.get(opts, :max_requests, 24)
    )
  end

  @doc """
  Runs the pipeline. Besides `Lemieux.Agent.Session`'s options it reads
  `:verify_command`, `:verify_timeout_ms`, `:verify_output_bytes` and
  `:verify_excerpt_bytes`.
  """
  @impl true
  @spec run(input :: Lemieux.Agent.input(), opts :: keyword()) :: Lemieux.Agent.result()
  def run(%{prompt: _prompt, cwd: cwd, timeout_ms: _timeout} = input, opts) when is_list(opts) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :timeout_ms, input.timeout_ms)

    with {:ok, task} <- session(:task, input, opts, deadline) do
      discovery = Discovery.discover(cwd, opts)
      first = check(discovery, cwd, opts)

      if retry?(first, deadline),
        do: retry(input, opts, deadline, task, discovery, first),
        else: {:ok, observe([task], discovery, [first])}
    end
  end

  defp retry(input, opts, deadline, task, discovery, first) do
    retry_input = %{input | prompt: retry_prompt(input.prompt, first, opts)}

    with {:ok, retry} <- session(:retry, retry_input, opts, deadline) do
      {:ok, observe([task, retry], discovery, [first, check(discovery, input.cwd, opts)])}
    end
  end

  defp session(role, input, opts, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 1)

    case Session.run(%{input | timeout_ms: remaining}, Keyword.put(opts, :timeout_ms, remaining)) do
      {:ok, observation} -> {:ok, {role, observation}}
      # The deadline expired mid-session. That is an observation with
      # evidence, not a broken runner, and the composition reports it as such.
      {:error, :timeout, observation} -> {:ok, {role, observation}}
      {:error, _reason} = error -> error
      {:error, _reason, _observation} = error -> error
    end
  end

  defp check(:none, _cwd, _opts), do: nil

  defp check({:ok, %{command: command}}, cwd, opts) do
    check_opts =
      [
        timeout_ms: Keyword.get(opts, :verify_timeout_ms, 120_000),
        max_output_bytes: Keyword.get(opts, :verify_output_bytes, 16_384)
      ] ++ environment(opts)

    Check.run(command, cwd, check_opts)
  end

  # The check runs where the session's tools ran. A host that supplied an
  # environment for the session gets the same one here.
  defp environment(opts) do
    case get_in(opts, [:session_options, :environment]) do
      nil -> []
      environment -> [environment: environment]
    end
  end

  defp retry?(nil, _deadline), do: false

  defp retry?(%{"status" => status}, deadline),
    do: status != "passed" and deadline > System.monotonic_time(:millisecond)

  defp retry_prompt(prompt, run, opts) do
    excerpt =
      Check.excerpt(
        run["output"],
        Keyword.get(opts, :verify_excerpt_bytes, @default_excerpt_bytes)
      )

    """
    #{prompt}

    An earlier attempt at this task left the project's own check failing. \
    Fix the code so the check passes, without editing the tests: do not edit, \
    delete or weaken test files or the check command. If you believe the check \
    itself is wrong, say so in your answer instead of changing it. Run the \
    command yourself before you finish.

    The project's own check failed: `#{run["command"]}` #{ending(run)}.
    Its output ended with:

    ```
    #{excerpt}
    ```
    """
  end

  defp ending(%{"status" => "failed", "exit_status" => status}),
    do: "exited with exit status #{status}"

  defp ending(%{"status" => "timed_out", "timeout_ms" => ms}),
    do: "timed out after #{ms}ms and was killed"

  defp ending(%{"status" => "output_limit"}),
    do: "printed more than the output limit and was stopped"

  defp ending(%{"status" => "failed_to_run", "error" => error}), do: "could not be run (#{error})"

  defp observe(sessions, discovery, runs) do
    observations = Enum.map(sessions, &elem(&1, 1))
    {_role, last} = List.last(sessions)

    %{
      "status" => last["status"],
      "answer" => last["answer"] || "",
      "finish_reason" => last["finish_reason"],
      "session_id" => last["session_id"],
      "session_ids" => Enum.map(observations, & &1["session_id"]),
      "sessions" =>
        Enum.map(sessions, fn {role, observation} ->
          observation |> Map.delete("transcript") |> Map.put("role", Atom.to_string(role))
        end),
      "transcript" => Enum.flat_map(observations, &(&1["transcript"] || [])),
      "usage" => Totals.sum(Enum.map(observations, &(&1["usage"] || %{}))),
      "resources" => Totals.sum(Enum.map(observations, &(&1["resources"] || %{}))),
      "tool_metrics" => Totals.sum(Enum.map(observations, &(&1["tool_metrics"] || %{}))),
      "changed_paths" =>
        observations |> Enum.flat_map(&(&1["changed_paths"] || [])) |> Enum.uniq(),
      "safety_violations" => nil,
      "verification" => verification(discovery, runs, sessions)
    }
  end

  defp verification(discovery, runs, sessions) do
    {command, source} =
      case discovery do
        {:ok, %{command: command, discovered_from: source}} -> {command, source}
        :none -> {nil, nil}
      end

    statuses = Enum.map(runs, &status/1)

    %{
      "command" => command,
      "discovered_from" => source,
      "first_status" => List.first(statuses) || "not_run",
      "retry?" => length(runs) == 2,
      "final_status" => List.last(statuses) || "not_run",
      "runs" => Enum.reject(runs, &is_nil/1),
      "retry_changed_tests" => retry_changed_tests(sessions)
    }
  end

  defp status(nil), do: "not_run"
  defp status(%{"status" => status}), do: status

  defp retry_changed_tests(sessions) do
    case List.keyfind(sessions, :retry, 0) do
      {:retry, observation} ->
        observation |> Map.get("changed_paths", []) |> Enum.filter(&test_path?/1)

      nil ->
        []
    end
  end

  @test_dirs ~w(test tests spec __tests__)
  @test_file ~r/^(test_.*|.*_test\..+|.*\.(test|spec)\..+)$/

  defp test_path?(path) do
    segments = Path.split(path)
    directories = Enum.drop(segments, -1)

    Enum.any?(directories, &(&1 in @test_dirs)) or Regex.match?(@test_file, List.last(segments))
  end
end
