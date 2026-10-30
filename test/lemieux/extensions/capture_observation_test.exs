defmodule Lemieux.Extensions.CaptureObservationTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Lemieux.Contract
  alias Lemieux.Entry
  alias Lemieux.Extensions.Capture
  alias Lemieux.Extensions.Capture.Inputs
  alias Lemieux.Extensions.Capture.Storage
  alias Lemieux.Harness
  alias Lemieux.Hooks
  alias Lemieux.Request
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defmodule Source do
    def read({:error, reason}, _id), do: {:error, reason}
    def read(entries, _id), do: {:ok, entries}
  end

  defmodule SlowEnvironment do
    def stream_file(owner, _cwd, _path) do
      send(owner, {:capture_worker, self()})

      receive do
        :continue -> {:error, :enoent}
      after
        60_000 -> {:error, :enoent}
      end
    end
  end

  defmodule BoundedPolicy do
    def stream_file(owner, _cwd, _path) do
      {:ok,
       Stream.map(1..3, fn index ->
         send(owner, {:policy_chunk, index})
         if index == 3, do: raise("policy was not bounded")
         String.duplicate("x", 4096)
       end)}
    end
  end

  defmodule UnsupportedEnvironment do
    def stream_file(_owner, _cwd, _path), do: {:error, :unsupported}
    def read_file(_owner, _cwd, _path), do: raise("unbounded fallback must not run")
  end

  setup %{tmp_dir: dir} do
    cwd = Path.join(dir, "workspace")
    File.mkdir_p!(cwd)
    File.write!(Path.join(cwd, "value"), "broken")
    context = %{cwd: cwd, session_id: "session", environment: Lemieux.Environment.local()}
    %{cwd: cwd, root: Path.join(dir, "capture"), context: context}
  end

  test "corrections remain review drafts with no mechanically promotable task", ctx do
    entries =
      entries([
        {:user, %{"text" => "fix it"}},
        {:assistant, %{"text" => "done"}},
        {:user, %{"text" => "No, this broke the value"}}
      ])

    harness = harness(ctx, entries)
    checkpoint(harness, ctx.context, entries)
    assert :ok = Hooks.session_end(harness.hooks, :normal, ctx.context)
    assert {:ok, [record]} = Capture.history(ctx.root, ctx.cwd)
    assert record["kind"] == "correction"
    assert record["qualification"] == "needs_review"
    assert record["task_correctness"] == "unassessed"

    assert {:error, :capture_replay_ineligible} =
             Capture.case_draft(record, Path.join(ctx.tmp_dir, "draft"))

    assert {:error, :capture_replay_ineligible} =
             Capture.validate_replay(record, Path.join(ctx.tmp_dir, "replay"), fn _, _ ->
               flunk("corrections cannot replay")
             end)

    refute JSON.encode!(record) =~ "No, this broke"
  end

  test "repeated failed tools and their recovery are separate deterministic observations", ctx do
    for recovery <- [false, true] do
      entries =
        entries(
          [{:user, %{"text" => "read"}}, {:tool_result, tool(true)}, {:tool_result, tool(true)}] ++
            if(recovery, do: [{:tool_result, tool(false)}], else: [])
        )

      context = %{ctx.context | session_id: "session-#{recovery}"}
      harness = harness(ctx, entries)
      checkpoint(harness, context, entries)
      assert :ok = Hooks.session_end(harness.hooks, :normal, context)
    end

    assert {:ok, records} = Capture.history(ctx.root, ctx.cwd)

    assert Enum.sort(Enum.map(records, & &1["kind"])) == [
             "repeated_tool_failure",
             "tool_recovery"
           ]

    assert Enum.all?(records, &(&1["qualification"] == "needs_review"))
  end

  test "duplicate terminal delivery never snapshots the repaired workspace", ctx do
    entries = failure_entries()
    harness = harness(ctx, entries)
    checkpoint(harness, ctx.context, Enum.take(entries, 1))
    assert :ok = Hooks.session_end(harness.hooks, :normal, ctx.context)
    assert {:ok, [original]} = Capture.history(ctx.root, ctx.cwd)
    File.write!(Path.join(ctx.cwd, "value"), "fixed")
    assert :ok = Hooks.session_end(harness.hooks, :normal, ctx.context)
    assert {:ok, [^original]} = Capture.history(ctx.root, ctx.cwd)
  end

  test "a resumed failed prompt cannot checkpoint its already repaired input", ctx do
    entries = failure_entries()
    harness = harness(ctx, entries)
    File.write!(Path.join(ctx.cwd, "value"), "fixed")
    checkpoint(harness, ctx.context, entries)
    Hooks.session_end(harness.hooks, :normal, ctx.context)
    assert {:ok, [record]} = Capture.history(ctx.root, ctx.cwd)
    refute record["inputs"]["complete"]

    assert record["inputs"]["skipped"] == [
             %{"path" => ".", "reason" => "prior_effects_without_checkpoint"}
           ]

    assert {:error, :capture_replay_ineligible} =
             Capture.validate_replay(record, Path.join(ctx.tmp_dir, "replay"), fn _, _ ->
               flunk("missing original inputs")
             end)
  end

  test "missing checkpoints and cancellation retain observations without inventing replay inputs",
       ctx do
    harness = harness(ctx, failure_entries())
    assert :ok = Hooks.session_end(harness.hooks, :cancelled, ctx.context)
    assert {:ok, [record]} = Capture.history(ctx.root, ctx.cwd)
    assert record["terminal"]["outcome"] == "unavailable"
    refute record["inputs"]["complete"]
    assert record["replay"] == %{"eligible" => false, "state" => "unverified"}
  end

  test "secret-shaped paths, symlinks and oversized inputs never become replay eligible", ctx do
    File.write!(Path.join(ctx.cwd, ".ENV"), "private-provider-key")
    File.write!(Path.join(ctx.cwd, "client_secret.json"), "secret-token")
    File.write!(Path.join(ctx.cwd, "large.txt"), String.duplicate("x", 1024))
    File.ln_s!(Path.join(ctx.cwd, "value"), Path.join(ctx.cwd, "link"))
    entries = failure_entries()
    harness = harness(ctx, entries, max_file_bytes: 64)
    checkpoint(harness, ctx.context, Enum.take(entries, 1))
    Hooks.session_end(harness.hooks, :normal, ctx.context)
    assert {:ok, [record]} = Capture.history(ctx.root, ctx.cwd)
    refute record["inputs"]["complete"]
    assert Enum.map(record["inputs"]["files"], & &1["path"]) == ["value"]
    refute JSON.encode!(record) =~ Base.encode64("private-provider-key")
    refute JSON.encode!(record) =~ Base.encode64("secret-token")
    assert length(record["inputs"]["skipped"]) == 4

    assert {:error, :capture_replay_ineligible} =
             Capture.validate_replay(record, Path.join(ctx.tmp_dir, "replay"), fn _, _ ->
               flunk("incomplete inputs")
             end)
  end

  test "a successful or mismatched replay cannot qualify the original failure", ctx do
    record = captured(ctx)

    for status <- [0, 127] do
      assert {:error, :capture_replay_ineligible} =
               Capture.validate_replay(record, Path.join(ctx.tmp_dir, "replay-#{status}"), fn _,
                                                                                              command ->
                 assert command == "mix test"
                 {:ok, status}
               end)
    end
  end

  test "explicit replay creates a human-curated case using the frozen failing input", ctx do
    record = captured(ctx)

    assert {:ok, verified} =
             Capture.validate_replay(record, Path.join(ctx.tmp_dir, "replay"), fn path, _ ->
               assert File.read!(Path.join(path, "value")) == "broken"
               {:ok, 1}
             end)

    assert :ok = Capture.verify(verified)

    assert {:ok, draft} =
             Capture.case_draft(verified, Path.join(ctx.tmp_dir, "drafts"),
               prompt: "Repair value",
               verifier: ["true"]
             )

    assert JSON.decode!(File.read!(draft.record_path))["feedback"]["actor"] == %{
             "type" => "system",
             "id" => "lemieux.capture"
           }

    assert draft.status == :draft
    assert File.read!(Path.join(draft.task.cwd, "value")) == "broken"
    assert draft.task.grader.command == ["sh", "-c", "mix test"]
  end

  test "unavailable storage and transcript errors are visible without bodies and never deny requests",
       ctx do
    File.write!(ctx.root, "occupied")
    harness = harness(ctx, {:error, "private-transcript-body"})

    log =
      capture_log(fn ->
        checkpoint(harness, ctx.context, Enum.take(failure_entries(), 1))
        assert :ok = Hooks.session_end(harness.hooks, :normal, ctx.context)
      end)

    assert log =~ "lmx capture: evidence unavailable"
    refute log =~ "private-transcript-body"
    assert File.read!(ctx.root) == "occupied"
  end

  test "a blocked environment is killed within the observation budget", ctx do
    context = %{ctx.context | environment: {SlowEnvironment, self()}}
    harness = harness(ctx, failure_entries(), timeout_ms: 20)
    log = capture_log(fn -> checkpoint(harness, context, Enum.take(failure_entries(), 1)) end)
    assert_receive {:capture_worker, pid}
    refute Process.alive?(pid)
    assert log =~ "evidence unavailable"
    refute File.exists?(ctx.root)
  end

  test "unsupported streaming never falls back to a whole-file read", ctx do
    context = %{ctx.context | environment: {UnsupportedEnvironment, self()}}
    harness = harness(ctx, failure_entries())

    assert capture_log(fn ->
             checkpoint(harness, context, Enum.take(failure_entries(), 1))
             Hooks.session_end(harness.hooks, :normal, context)
           end) == ""

    refute File.exists?(ctx.root)
  end

  test "oversized project policy is stopped before consuming the stream", ctx do
    context = %{ctx.context | environment: {BoundedPolicy, self()}}
    harness = harness(ctx, failure_entries())
    checkpoint(harness, context, Enum.take(failure_entries(), 1))
    assert_receive {:policy_chunk, 1}
    assert_receive {:policy_chunk, 2}
    refute_receive {:policy_chunk, 3}, 20
    refute File.exists?(ctx.root)
  end

  test "project opt out and invalid policy are fail closed, including extra fields", ctx do
    File.mkdir_p!(Path.join(ctx.cwd, ".lmx"))

    for bytes <- [~s({"enabled":false,"extra":true}), "invalid", String.duplicate("x", 4097)] do
      File.write!(Path.join(ctx.cwd, ".lmx/capture.json"), bytes)
      harness = harness(ctx, failure_entries())
      checkpoint(harness, ctx.context, Enum.take(failure_entries(), 1))
      Hooks.session_end(harness.hooks, :normal, ctx.context)
      refute File.exists?(ctx.root)
    end
  end

  test "child sessions and aside work produce no capture side effects", ctx do
    for extra <- [%{root_session_id: "parent"}, %{aside: :reflection}] do
      context = Map.merge(ctx.context, extra)
      harness = harness(ctx, failure_entries())
      checkpoint(harness, context, Enum.take(failure_entries(), 1))
      Hooks.session_end(harness.hooks, :normal, context)
      refute File.exists?(ctx.root)
    end
  end

  test "retention is scoped and forgetting removes pending and completed captures", ctx do
    record = captured(ctx)
    other = ctx.cwd <> "-other"
    assert {:ok, []} = Capture.history(ctx.root, other)
    assert :ok = Capture.prune(ctx.root, ctx.cwd, 1, 1)
    assert {:ok, [^record]} = Capture.history(ctx.root, ctx.cwd)

    old =
      record
      |> Map.drop(~w(id sha256))
      |> Map.put("created_at", "2000-01-01T00:00:00Z")
      |> sign_record()

    assert :ok = Capture.retain(ctx.root, old)
    assert :ok = Capture.prune(ctx.root, ctx.cwd, 1, 1)
    assert {:ok, [^record]} = Capture.history(ctx.root, ctx.cwd)
    assert :ok = Capture.forget(ctx.root, ctx.cwd)
    assert {:ok, []} = Capture.history(ctx.root, ctx.cwd)
  end

  test "forget prevents late terminal delivery from recreating an earlier capture", ctx do
    entries = failure_entries()
    harness = harness(ctx, entries)
    checkpoint(harness, ctx.context, Enum.take(entries, 1))
    assert :ok = Capture.forget(ctx.root, ctx.cwd)
    assert :ok = Hooks.session_end(harness.hooks, :normal, ctx.context)
    assert {:ok, []} = Capture.history(ctx.root, ctx.cwd)

    fresh_entries = failure_entries()
    fresh = harness(ctx, fresh_entries)
    checkpoint(fresh, ctx.context, Enum.take(fresh_entries, 1))
    assert :ok = Hooks.session_end(fresh.hooks, :normal, ctx.context)
    assert {:ok, [record]} = Capture.history(ctx.root, ctx.cwd)
    assert record["prompt_id"] == hd(fresh_entries).id
  end

  test "forget refuses a live capture writer without removing its content", ctx do
    record = captured(ctx)
    locks = ctx.root <> "-locks"
    File.mkdir_p!(locks)
    id = Contract.digest(Storage.scope(ctx.cwd))
    assert {:ok, claim} = JSONL.lock(%{dir: locks}, id)

    try do
      assert {:error, _busy} = Capture.forget(ctx.root, ctx.cwd)
      assert {:ok, [^record]} = Capture.history(ctx.root, ctx.cwd)
    after
      JSONL.unlock(%{dir: locks}, id, claim)
    end
  end

  test "private ignored publication rejects symlinks, corrupt artifacts and tampered bytes",
       ctx do
    record = captured(ctx)
    directory = Storage.directory(ctx.root, Storage.scope(ctx.cwd))
    assert File.read!(Path.join(directory, ".gitignore")) == "*\n"
    assert Bitwise.band(File.stat!(directory).mode, 0o777) == 0o700

    assert Bitwise.band(File.stat!(Path.join(directory, record["id"] <> ".json")).mode, 0o777) ==
             0o600

    assert {:error, _} =
             Capture.verify(
               put_in(
                 record,
                 ["inputs", "files", Access.at(0), "content"],
                 Base.encode64("fixed")
               )
             )

    assert {:error, _} = Capture.materialize(record, ctx.cwd)
    File.ln_s!(ctx.cwd, Path.join(ctx.tmp_dir, "linked"))

    assert {:error, :capture_symlink} =
             Capture.materialize(record, Path.join(ctx.tmp_dir, "linked/replay"))

    File.write!(Path.join(directory, ".gitignore"), "")
    assert {:error, :capture_ignore_conflict} = Capture.retain(ctx.root, record)
    File.write!(Path.join(directory, record["id"] <> ".json"), "{}")
    assert {:error, :invalid_capture_record} = Capture.history(ctx.root, ctx.cwd)
  end

  test "input verification rejects traversal, duplicate files and fabricated eligibility", ctx do
    record = captured(ctx)
    input = record["inputs"]
    [file] = input["files"]

    for files <- [
          [Map.put(file, "path", "../escape")],
          [file, file],
          [Map.put(file, "path", ".env")],
          [Map.put(file, "path", ".lmx/config.json")]
        ] do
      altered = input |> Map.drop(["sha256"]) |> Map.put("files", files) |> sign()
      assert {:error, :invalid_capture_inputs} = Inputs.verify(altered)
    end

    fabricated =
      record
      |> Map.drop(~w(id sha256))
      |> Map.put("replay", %{"eligible" => true})
      |> sign_record()

    assert {:error, :invalid_capture_record} = Capture.verify(fabricated)
  end

  test "effective read denials and approval requirements exclude input bytes without asking",
       ctx do
    for answer <- [{:deny, "private"}, {:pending, %{permission: %{}}}] do
      context =
        Map.put(ctx.context, :hooks,
          before_tool_call: fn call, _ ->
            if call.arguments["path"] == "value", do: answer, else: :allow
          end
        )

      harness = harness(ctx, failure_entries())
      checkpoint(harness, context, Enum.take(failure_entries(), 1))
      Hooks.session_end(harness.hooks, :normal, context)
      assert {:ok, records} = Capture.history(ctx.root, ctx.cwd)
      assert Enum.all?(records, &(&1["inputs"]["files"] == [] and not &1["inputs"]["complete"]))
      Capture.forget(ctx.root, ctx.cwd)
    end
  end

  test "finite capture options reject zero, unbounded and inconsistent limits", ctx do
    for opts <- [
          [max_input_bytes: 0],
          [max_files: 513],
          [timeout_ms: 2001],
          [max_file_bytes: 1_048_577],
          [max_input_bytes: 10],
          [verification_commands: :all]
        ] do
      assert {:error, :invalid_capture_configuration} =
               Capture.init([dir: ctx.root, store: {Source, []}] ++ opts)
    end
  end

  defp captured(ctx) do
    entries = failure_entries()
    harness = harness(ctx, entries)
    checkpoint(harness, ctx.context, Enum.take(entries, 1))
    assert :ok = Hooks.session_end(harness.hooks, :normal, ctx.context)
    assert {:ok, [record]} = Capture.history(ctx.root, ctx.cwd)
    record
  end

  defp checkpoint(harness, context, entries) do
    request = Request.new("scripted:offline", entries: entries)
    assert {:ok, ^request} = Hooks.prepare_next_turn(harness.hooks, request, context)
  end

  defp harness(ctx, entries, opts \\ []) do
    {:ok, harness} =
      Harness.assemble(Harness.new(), [
        {Capture, [dir: ctx.root, store: {Source, entries}, timeout_ms: 2000] ++ opts}
      ])

    harness
  end

  defp failure_entries do
    entries([
      {:user, %{"text" => "check"}},
      {:tool_result,
       %{
         "name" => "bash",
         "arguments" => %{"command" => "mix test"},
         "structured_content" => %{"status" => "exited", "exit_status" => 1},
         "error" => false
       }}
    ])
  end

  defp tool(error),
    do: %{"name" => "read", "arguments" => %{"path" => "missing"}, "error" => error}

  defp entries(values),
    do:
      values
      |> Enum.with_index(1)
      |> Enum.map(fn {{type, payload}, seq} -> Entry.new(type, payload, seq: seq) end)

  defp sign(map), do: Map.put(map, "sha256", Contract.digest(map))
  defp sign_record(map), do: map |> Map.put("id", "capture_" <> Contract.digest(map)) |> sign()
end
