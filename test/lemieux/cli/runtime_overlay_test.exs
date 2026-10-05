defmodule Lemieux.CLI.RuntimeOverlayTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Learning.Overlay
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  test "a session started with a discovered overlay shows the learned tool text and records the asset",
       %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))

    personal = Path.join(tmp_dir, "personal")
    File.mkdir_p!(personal)

    # The repository's overlay adds prompt text; tool descriptions are the
    # person's own overlay's to give.
    :ok =
      Overlay.export(
        %Overlay{system_suffix: "Learned: rerun the check.", qualification: "confirmed"},
        Path.join([repo, ".lmx", "harness.json"])
      )

    :ok =
      Overlay.export(
        %Overlay{
          tool_descriptions: %{"write" => "Write only inside the repository."},
          qualification: "confirmed"
        },
        Path.join(personal, "harness.json")
      )

    {:ok, workspace} =
      Discovery.discover(repo,
        personal_dir: personal,
        claude_personal_dir: Path.join(personal, "c"),
        codex_personal_dir: Path.join(personal, "x"),
        agents_personal_dir: Path.join(personal, "a")
      )

    assert {:ok, options} = Options.parse([])
    supervisor = :"lemieux_cli_overlay_test_#{System.unique_integer([:positive])}"
    owner = self()

    provider =
      Scripted.new([
        fn request ->
          send(owner, {:request, request})
          Scripted.complete("ok")
        end
      ])

    assert {:ok, session} =
             Runtime.start_session(options,
               provider: provider,
               store: JSONL.new(Path.join(tmp_dir, "sessions")),
               supervisor: supervisor,
               workspace: workspace,
               cwd: repo
             )

    :ok = Session.prompt(session, "hello")
    assert_receive {:request, request}, 5_000

    write = Enum.find(request.tools, &(Lemieux.Tool.name(&1) == "write"))
    assert Lemieux.Tool.description(write) == "Write only inside the repository."
    assert request.system =~ "Learned: rerun the check."

    snapshot =
      Enum.find_value(Session.snapshot(session).entries, fn entry ->
        if entry.type == :harness_snapshot, do: entry.payload
      end)

    assert [%{"type" => "harness_overlay", "qualification" => "confirmed"}] =
             snapshot["resolved_assets"]

    Supervisor.stop(supervisor)
  end
end
