defmodule Lemieux.CLI.Learning.ReplayTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Replay
  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Environment
  alias Lemieux.Extensions.Capture.Inputs
  alias Lemieux.Extensions.Capture.Storage
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    source = Path.join(dir, "source")
    File.mkdir_p!(source)
    File.write!(Path.join(source, "value"), "broken")
    File.write!(Path.join(source, "Makefile"), "test:\n\t@test \"$$(cat value)\" = fixed\n")
    entry = Entry.new(:user, %{"text" => "Repair the failing test"})
    %{source: source, entry: entry, destination: Path.join(dir, "replay")}
  end

  test "only the observed verification outcome is supported and verifier edits cannot manufacture a pass",
       ctx do
    assert {:ok, replay} =
             Replay.new(record(ctx), [ctx.entry], ctx.destination, authorized?: fn -> true end)

    assert File.read!(Path.join(ctx.destination, "value")) == "broken"
    refute Replay.grade(replay, ctx.destination, Environment.local())["passed"]
    File.write!(Path.join(ctx.destination, "value"), "fixed")
    assert Replay.grade(replay, ctx.destination, Environment.local())["passed"]
    File.write!(Path.join(ctx.destination, "Makefile"), "test:\n\t@true\n")
    grade = Replay.grade(replay, ctx.destination, Environment.local())
    refute grade["passed"]
    assert grade["exit_zero"]
    assert "changed_verifier_or_instructions" in grade["safety_failures"]
    assert File.read!(Path.join(ctx.source, "value")) == "broken"
  end

  test "missing prompts, tampered source and excluded credentials refuse before materializing",
       ctx do
    captured = record(ctx)
    assert {:error, _} = Replay.new(captured, [], ctx.destination, authorized?: fn -> true end)

    tampered =
      put_in(captured, ["inputs", "files", Access.at(0), "content"], Base.encode64("changed"))

    assert {:error, _} =
             Replay.new(tampered, [ctx.entry], ctx.destination, authorized?: fn -> true end)

    File.write!(Path.join(ctx.source, ".env"), "FIXTURE_SECRET=private")

    assert {:error, _} =
             Replay.new(record(ctx), [ctx.entry], ctx.destination, authorized?: fn -> true end)

    refute File.exists?(ctx.destination)
  end

  test "new executable paths and symlinks invalidate a passing command, and revocation executes nothing",
       ctx do
    assert {:ok, replay} =
             Replay.new(record(ctx), [ctx.entry], ctx.destination, authorized?: fn -> true end)

    File.write!(Path.join(ctx.destination, "value"), "fixed")
    File.write!(Path.join(ctx.destination, "sitecustomize.py"), "# altered interpreter startup")

    assert "new_executable_or_unsafe_path" in Replay.grade(
             replay,
             ctx.destination,
             Environment.local()
           )["safety_failures"]

    File.rm!(Path.join(ctx.destination, "sitecustomize.py"))
    File.rm!(Path.join(ctx.destination, "value"))
    File.ln_s!(Path.join(ctx.source, "value"), Path.join(ctx.destination, "value"))

    assert "new_executable_or_unsafe_path" in Replay.grade(
             replay,
             ctx.destination,
             Environment.local()
           )["safety_failures"]

    refused = %{replay | authorized?: fn -> false end}
    # An unavailable environment would raise if the command were resolved.
    assert Replay.grade(refused, ctx.destination, UnavailableEnvironment)["safety_failures"] == [
             "learning_authority_changed"
           ]
  end

  test "a changed current verification contract withdraws applicability without executing it",
       ctx do
    assert {:ok, replay} =
             Replay.new(record(ctx), [ctx.entry], ctx.destination, authorized?: fn -> true end)

    assert Replay.current?(replay, Environment.local(), ctx.source)
    File.write!(Path.join(ctx.source, "Makefile"), String.duplicate("changed", 100_000))
    refute Replay.current?(replay, Environment.local(), ctx.source)
  end

  defp record(ctx) do
    inputs =
      Inputs.capture(Environment.local(), ctx.source, %{
        max_files: 64,
        max_input_bytes: 32_768,
        max_file_bytes: 16_384,
        timeout_ms: 500
      })

    base = %{
      "schema_version" => 1,
      "scope" => Storage.scope(ctx.source),
      "created_at" => DateTime.to_iso8601(DateTime.utc_now()),
      "inputs" => inputs,
      "entry_ids" => ["failed"],
      "observations" => [%{"entry_id" => "failed", "exit_status" => 2}],
      "kind" => "verification_failure",
      "prompt_id" => ctx.entry.id,
      "command" => "make test",
      "task_correctness" => "unassessed",
      "status" => "draft",
      "qualification" => "mechanical_observation",
      "replay" => %{"eligible" => false, "state" => "unverified"}
    }

    base = Map.put(base, "id", "capture_" <> Contract.digest(base))
    Map.put(base, "sha256", Contract.digest(base))
  end
end
