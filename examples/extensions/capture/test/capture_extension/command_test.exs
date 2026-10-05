defmodule CaptureExtension.CommandTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias CaptureExtension.Command
  alias CaptureExtension.Config
  alias Lemieux.Entry
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "Makefile"), "test:\n\tfalse\n")

    sessions_dir = Path.join(tmp_dir, "sessions")
    session_id = Lemieux.ID.generate()

    env = %{
      "LMX_SESSIONS_DIR" => sessions_dir,
      "LMX_CAPTURE_FEEDBACK_DIR" => Path.join(tmp_dir, "feedback"),
      "LMX_CAPTURE_DRAFTS_DIR" => Path.join(tmp_dir, "drafts")
    }

    %{
      workspace: workspace,
      store: JSONL.new(sessions_dir),
      session_id: session_id,
      env: env,
      input:
        JSON.encode!(%{
          "session_id" => session_id,
          "cwd" => workspace,
          "hook_event_name" => "sessionEnd",
          "reason" => "normal",
          "timestamp" => "2026-09-17T00:00:00Z"
        })
    }
  end

  test "a sessionEnd for a failing session answers with the draft and logs the line", context do
    :ok = Store.append(context.store, context.session_id, failing("make test"))

    {result, stderr} = with_stderr(fn -> Command.run(context.input, context.env) end)

    assert {:ok, output} = result
    assert output["class"] == "mechanical"

    assert output["draft"] ==
             Path.join(
               context.env["LMX_CAPTURE_DRAFTS_DIR"],
               "case_" <> String.trim_leading(output["feedback_id"], "fb_")
             )

    assert output["promote"] =~ "lmx corpus promote #{output["draft"]}"
    assert File.dir?(Path.join(output["draft"], "fixture"))

    log = File.read!(Path.join(context.env["LMX_CAPTURE_DRAFTS_DIR"], "capture.log"))

    assert log ==
             "capture: drafted #{output["draft"]} (`make test` exited 2); review it, then: #{output["promote"]}\n"

    assert String.trim(stderr) == String.trim(log)
  end

  test "a clean session answers with an empty object and writes nothing", context do
    :ok = Store.append(context.store, context.session_id, [Entry.new(:user, %{"text" => "hi"})])

    assert {:ok, %{}} = Command.run(context.input, context.env)
    refute File.exists?(context.env["LMX_CAPTURE_DRAFTS_DIR"])
  end

  test "other events are ignored rather than refused", context do
    input = JSON.encode!(%{"hook_event_name" => "postToolUse", "session_id" => "s", "cwd" => "/"})
    assert {:ok, %{}} = Command.run(input, context.env)
  end

  test "malformed or empty input is an error the operator can read", context do
    assert {:error, "hook input is not a JSON object"} = Command.run("[1, 2]", context.env)
    assert {:error, "hook input is not a JSON object"} = Command.run("{not json", context.env)
    assert {:error, "no hook input on stdin"} = Command.run(:eof, context.env)

    assert {:error, "hook input needs hook_event_name, session_id and cwd"} =
             Command.run(~s({"reason": "normal"}), context.env)
  end

  test "the environment configures patterns and bounds", context do
    :ok = Store.append(context.store, context.session_id, failing("just check"))
    env = Map.put(context.env, "LMX_CAPTURE_VERIFICATION_PATTERNS", "just check | mix test")

    assert {:ok, %{"class" => "mechanical"}} =
             with_stderr(fn -> Command.run(context.input, env) end) |> elem(0)

    assert {:error, "LMX_CAPTURE_MAX_FILE_BYTES must be a positive integer"} =
             Command.run(
               context.input,
               Map.put(context.env, "LMX_CAPTURE_MAX_FILE_BYTES", "lots")
             )

    assert {:ok, config} =
             Config.from_env(Map.put(context.env, "LMX_CAPTURE_MAX_TOTAL_BYTES", "4096"))

    assert config.max_total_bytes == 4096
    assert config.sessions_dir == context.env["LMX_SESSIONS_DIR"]
    assert config.feedback_dir == context.env["LMX_CAPTURE_FEEDBACK_DIR"]
  end

  test "with no capture variables the defaults are lmx's own", %{tmp_dir: tmp_dir} do
    assert {:ok, config} = Config.from_env(%{"LMX_SESSIONS_DIR" => Path.join(tmp_dir, "s")})
    assert config.feedback_dir == Path.join(tmp_dir, "feedback")
    assert config.drafts_dir == ".lmx/drafts"
    assert config.verification_patterns == Config.default_verification_patterns()
  end

  defp with_stderr(fun) do
    stderr = capture_io(:stderr, fn -> send(self(), {:result, fun.()}) end)
    assert_received {:result, result}
    {result, stderr}
  end

  defp failing(command) do
    [
      Entry.new(:user, %{"text" => "make it pass"}),
      Entry.new(:assistant, %{
        "content" => [],
        "tool_calls" => [
          %{"id" => "c1", "name" => "bash", "arguments" => %{"command" => command}}
        ]
      }),
      Entry.new(:tool_result, %{
        "call_id" => "c1",
        "name" => "bash",
        "arguments" => %{},
        "output" => "[exit status 2]",
        "error" => false,
        "structured_content" => %{"status" => "exited", "exit_status" => 2}
      })
    ]
  end
end
