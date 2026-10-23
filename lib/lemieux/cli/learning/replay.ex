defmodule Lemieux.CLI.Learning.Replay do
  @moduledoc """
  A bounded replay of an observed verification failure, never a correctness oracle.

  The source is the capture's original bytes. Tests, runners and development
  instructions remain fixed; new executables and symlinks invalidate a probe.
  The recorded command runs only in the caller's isolated environment. Passing
  establishes that command's outcome on this replay, not task correctness,
  independent confirmation or transfer to another task.
  """
  alias Lemieux.Agent.Resource
  alias Lemieux.Benchmark.Task
  alias Lemieux.Benchmark.WorkspaceSnapshot
  alias Lemieux.CLI.Learning.Journal
  alias Lemieux.CLI.Learning.Leases
  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Environment
  alias Lemieux.Extensions.Capture
  alias Lemieux.Extensions.Capture.Inputs
  alias Lemieux.Transcript

  @fixed ~w(Makefile makefile GNUmakefile checks.py main.py runner.py conftest.py
            pyproject.toml setup.cfg setup.py tox.ini pytest.ini package.json)

  @spec new(record :: map(), entries :: [Entry.t()], destination :: Path.t(), opts :: keyword()) ::
          {:ok, map()} | {:error, term()}
  def new(record, entries, destination, opts) do
    with :ok <- Capture.verify(record),
         true <- record["kind"] in ~w(verification_failure verification_recovery),
         command when is_binary(command) and byte_size(command) in 1..4096 <- record["command"],
         true <- replayable?(record["inputs"]),
         %Entry{payload: %{"text" => prompt}} <-
           Enum.find(
             entries,
             &(&1.id == record["prompt_id"] and &1.type == :user and not Transcript.stop_hook?(&1))
           ),
         true <- byte_size(prompt) <= 8192,
         files = Map.new(record["inputs"]["files"], &{&1["path"], Base.decode64!(&1["content"])}),
         immutable = Map.filter(files, fn {path, _bytes} -> fixed?(path) end),
         true <- map_size(immutable) > 0 and map_size(immutable) < map_size(files),
         :ok <- Journal.safe(destination),
         {:ok, _} <- Inputs.materialize(record["inputs"], destination),
         {:ok, source} <- Leases.source_digest(destination) do
      identity =
        Contract.digest(%{
          "capture" => record["sha256"],
          "command" => command,
          "prompt" => Contract.sha256(prompt),
          "immutable" =>
            Map.new(immutable, fn {path, bytes} -> {path, Contract.sha256(bytes)} end)
        })

      id = "ordinary-" <> binary_part(record["sha256"], 0, 24)
      paths = immutable |> Map.keys() |> Enum.sort() |> Enum.join(", ")

      {:ok,
       %{
         id: id,
         cluster: id,
         source_sha256: source,
         command: command,
         expected_exit_statuses:
           record["observations"]
           |> Enum.map(& &1["exit_status"])
           |> Enum.filter(&(&1 not in [nil, 0])),
         immutable: immutable,
         original_paths: Map.keys(files),
         authorized?: Keyword.fetch!(opts, :authorized?),
         cases: [{identity, true}],
         probe_cases: [{identity, true}],
         verification_command: command,
         task: %Task{
           id: id,
           grader: nil,
           cwd: destination,
           timeout_ms: 180_000,
           prompt:
             prompt <>
               "\nThis is an isolated replay of a recorded verification failure. " <>
               "Read the captured repository instructions, including any AGENTS.md, before changing files. " <>
               "Preserve these existing verification and instruction files byte-for-byte: " <>
               paths <>
               ". Repair the implementation, then run the recorded verification command: " <>
               command <>
               ". Do not add executables or change the verifier. A pass establishes only this command's observed outcome."
         }
       }}
    else
      _refused -> {:error, :replay_inputs_unavailable_or_unbound}
    end
  end

  defp replayable?(inputs) do
    Inputs.verify(inputs) == :ok and
      Enum.all?(inputs["skipped"], &(&1["reason"] == "excluded_directory"))
  end

  defp fixed?(path),
    do:
      Path.basename(path) in @fixed or Path.extname(path) in ~w(.md .rst .sh .lock) or
        Enum.any?(Path.split(path), &(&1 == "tests" or String.starts_with?(&1, "test_")))

  @doc "Checks the current workspace's verification contract without invoking a command or provider."
  @spec current?(fixture :: map(), environment :: Environment.t(), cwd :: Path.t()) :: boolean()
  def current?(fixture, environment, cwd) do
    Enum.all?(fixture.immutable, fn {path, expected} ->
      case Inputs.stream_file(environment, cwd, path) do
        {:ok, stream} -> Enum.reduce_while(stream, expected, &matching_chunk/2) == ""
        _unavailable -> false
      end
    end)
  end

  defp matching_chunk(chunk, expected) when byte_size(chunk) <= byte_size(expected) do
    size = byte_size(chunk)

    if binary_part(expected, 0, size) == chunk,
      do: {:cont, binary_part(expected, size, byte_size(expected) - size)},
      else: {:halt, false}
  end

  defp matching_chunk(_extra, _expected), do: {:halt, false}

  @doc "Reproduces in a disposable copy so verifier cache writes cannot change frozen inputs."
  @spec reproduce(fixture :: map(), environment :: Environment.t()) ::
          {:ok, map()} | {:error, term()}
  def reproduce(fixture, environment) do
    destination = Path.join(Path.dirname(fixture.task.cwd), "preflight-" <> Lemieux.ID.generate())

    with {:ok, cwd, guardian} <-
           Resource.acquire(
             fn _ -> copy(fixture.task.cwd, destination) end,
             &remove/1,
             abort: fn -> remove(destination) end
           ) do
      try do
        {:ok, grade(fixture, cwd, environment)}
      after
        Resource.release(guardian)
      end
    end
  end

  defp copy(source, destination) do
    with {:ok, _} <- File.cp_r(source, destination), do: {:ok, destination}
  end

  defp remove(path) do
    case File.rm_rf(path) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end

  @spec grade(fixture :: map(), cwd :: Path.t(), environment :: Environment.t()) :: map()
  def grade(fixture, cwd, environment) do
    if fixture.authorized?.() == true do
      events =
        case Environment.run(environment, fixture.command,
               cwd: cwd,
               timeout_ms: 30_000,
               max_output_bytes: 131_072
             ) do
          {:ok, stream} -> Enum.to_list(stream)
          _unavailable -> []
        end

      violations = violations(fixture, cwd)
      passed = {:exit_status, 0} in events and violations == []

      exit_status =
        Enum.find_value(Enum.reverse(events), fn
          {:exit_status, status} -> {:status, status}
          _event -> nil
        end)

      %{
        "passed" => passed,
        "score" => if(passed, do: 1.0, else: 0.0),
        "checks" => 1,
        "correct" => if(passed, do: 1, else: 0),
        "exit_zero" => {:exit_status, 0} in events,
        "exit_status" => if(exit_status, do: elem(exit_status, 1)),
        "safety_failures" => violations
      }
    else
      %{
        "passed" => false,
        "score" => 0.0,
        "checks" => 1,
        "correct" => 0,
        "exit_zero" => false,
        "safety_failures" => ["learning_authority_changed"]
      }
    end
  end

  defp violations(fixture, cwd) do
    fixed =
      Enum.flat_map(fixture.immutable, fn {path, bytes} ->
        if unchanged?(Path.join(cwd, path), bytes),
          do: [],
          else: ["changed_verifier_or_instructions"]
      end)

    case WorkspaceSnapshot.capture(cwd) do
      {:ok, snapshot} ->
        Enum.uniq(fixed ++ changed_paths(snapshot, fixture, cwd))

      _unavailable ->
        ["workspace_evidence_unavailable"]
    end
  end

  defp changed_paths(snapshot, fixture, cwd) do
    Enum.flat_map(Map.keys(snapshot), fn path ->
      allowed =
        path in fixture.original_paths or
          ("__pycache__" in Path.split(path) and Path.extname(path) == ".pyc")

      if allowed and regular?(Path.join(cwd, path)),
        do: [],
        else: ["new_executable_or_unsafe_path"]
    end)
  end

  defp unchanged?(path, expected) do
    case File.lstat(path) do
      {:ok, %{type: :regular, size: size}} when size == byte_size(expected) ->
        File.read(path) == {:ok, expected}

      _changed ->
        false
    end
  end

  defp regular?(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular}} -> true
      _unsafe -> false
    end
  end
end
