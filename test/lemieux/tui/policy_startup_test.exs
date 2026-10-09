defmodule Lemieux.TUI.PolicyStartupTest do
  # What a sitting is told as it starts, beyond the permission banner: what
  # `/undo` covers where commands are not recorded, and — for somebody with no
  # key who skipped the first-run panel — a first-prompt error that names no
  # vendor they never chose.
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.Entry
  alias Lemieux.TUI
  alias Lemieux.TUI.Notices
  alias Lemieux.TUI.Policy

  @moduletag :tmp_dir

  @undo_notice "/undo covers file-tool edits only here: not a git repository, " <>
                 "so what commands change is not recorded"

  setup %{tmp_dir: tmp_dir} do
    outside = Path.join(System.tmp_dir!(), "lmx-policy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(outside)
    on_exit(fn -> File.rm_rf!(outside) end)

    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(repo)
    {_output, 0} = System.cmd("git", ["init", "-q"], cd: repo, stderr_to_stdout: true)

    %{outside: outside, repo: repo, checkpoints: Path.join(tmp_dir, "checkpoints")}
  end

  defp started(opts) do
    [id: "01POLICY", model: "anthropic:claude-sonnet-5", test_mode: {80, 24}, permissions: nil]
    |> Keyword.merge(opts)
    |> TUI.new()
    |> sized()
    |> Policy.banner()
  end

  defp texts(state), do: Enum.map(Notices.items(state), & &1.text)

  # The way `Lemieux.TUI.Lifecycle` opens a sitting: the banner, then the
  # first-run panel, which a person looking around first leaves with Esc.
  defp skip_panel(state) do
    opened = TUI.FirstRun.open(state)
    assert opened.modal.kind == :first_run
    press(opened, "esc")
  end

  describe "what /undo covers" do
    test "outside a git repository the start says file-tool edits only", context do
      state = started(checkpoints: context.checkpoints, cwd: context.outside)

      assert texts(state) == [
               "full auto: tools run without asking · commands are not sandboxed",
               @undo_notice
             ]

      assert screen(state) =~ "/undo covers file-tool edits only here"
    end

    # The box is a temporary UI row; /doctor still explains the scope later.
    test "it is in the temporary notice box", context do
      state = started(checkpoints: context.checkpoints, cwd: context.outside)

      assert [{:notice_box, _id, items}] = state.lines
      assert Enum.any?(items, &(&1.text == @undo_notice))
    end

    test "in a git repository there is nothing to add", context do
      state = started(checkpoints: context.checkpoints, cwd: context.repo)

      assert texts(state) == ["full auto: tools run without asking · commands are not sandboxed"]
    end

    test "with checkpoints off /undo covers nothing, and this notice does not claim it does",
         context do
      state = started(checkpoints: nil, cwd: context.outside)

      refute Enum.any?(texts(state), &(&1 =~ "/undo"))
    end
  end

  describe "a start on a model nobody chose" do
    @missing {:missing_api_key, "anthropic", ":api_key option or ANTHROPIC_API_KEY env var"}

    defp row(id, credential),
      do: %{
        id: id,
        label: id,
        env: String.upcase(id) <> "_API_KEY",
        model: id <> ":m",
        credential: credential
      }

    defp keyless,
      do: %{providers: [row("anthropic", :missing), row("openai", :missing)], config_path: nil}

    test "the first prompt's missing key names no vendor, and says how to get going" do
      state = started(first_run: keyless()) |> skip_panel() |> info({:error, @missing})
      text = unwrapped(state)

      assert text =~ "no provider key was found"
      assert text =~ "ANTHROPIC_API_KEY or OPENAI_API_KEY"
      assert text =~ "/provider ollama"
      refute text =~ "no API key for anthropic"
    end

    test "a provider chosen afterwards is named again" do
      state =
        started(first_run: keyless())
        |> skip_panel()
        |> info({:model_changed, "anthropic:claude-sonnet-5", "xai:grok-4.7"})
        |> info({:error, {:missing_api_key, "xai", "XAI_API_KEY env var"}})

      assert unwrapped(state) =~ "no API key for xai · set XAI_API_KEY, or switch with /provider"
    end

    # A model the person named has a provider they chose: the panel opens on
    # it (`:selected`), and the line names it.
    test "a model the person named keeps its vendor's name" do
      state =
        started(first_run: Map.put(keyless(), :selected, "anthropic"))
        |> skip_panel()
        |> info({:error, @missing})

      assert unwrapped(state) =~ "no API key for anthropic"
      refute unwrapped(state) =~ "no provider key was found"
    end

    # `--config none` starts on the placeholder beside keys it does not look
    # at. "No provider key was found" would be false there, and /provider to
    # the provider whose key is set is the way out the line already offers.
    test "beside a provider whose key is set, the line stays the vendor's" do
      setup = %{keyless() | providers: [row("anthropic", :missing), row("openai", :present)]}
      state = started(first_run: setup) |> skip_panel() |> info({:error, @missing})

      assert unwrapped(state) =~ "no API key for anthropic"
    end

    test "without a first-run panel nothing is marked" do
      assert started([]).conversation.model_chosen?
    end
  end

  # `lmx --resume ID` and `lmx -c` start on the transcript's model, while the
  # first-run setup still reads what chose the model that replaced it — a
  # guess — so it selects no provider either. Through the screen's own start
  # (`Lemieux.TUI.Lifecycle`), which hydrates the transcript before the
  # banner, as `lmx` does.
  describe "a resumed session" do
    @xai {:missing_api_key, "xai", "XAI_API_KEY env var"}

    defp mounted(snapshot) do
      setup = %{keyless() | providers: [row("anthropic", :missing), row("xai", :missing)]}
      session = fake_session(snapshot)

      assert {:ok, state} =
               TUI.mount(
                 test_mode: {80, 24},
                 start: fn -> {:ok, session} end,
                 first_run: setup,
                 permissions: nil
               )

      assert state.modal.kind == :first_run
      press(state, "esc")
    end

    defp transcript(id, entries),
      do: %{snapshot(id, entries) | model: "xai:grok-4.7", provider: "xai"}

    test "keeps its vendor in the first prompt's missing-key line" do
      state =
        "01RESUMED"
        |> transcript([Entry.new(:user, %{"text" => "where were we?"})])
        |> mounted()

      assert state.conversation.model_chosen?

      text = state |> info({:error, @xai}) |> unwrapped()

      assert text =~ "no API key for xai · set XAI_API_KEY, or switch with /provider"
      refute text =~ "no provider key was found"
    end

    # The same start with no conversation in it is the placeholder case.
    test "a new session through the same start is still one nobody chose" do
      state = "01FRESH" |> transcript([]) |> mounted()

      refute state.conversation.model_chosen?
      assert state |> info({:error, @xai}) |> unwrapped() =~ "no provider key was found"
    end
  end
end
