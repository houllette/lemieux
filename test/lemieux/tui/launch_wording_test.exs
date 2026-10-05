defmodule Lemieux.TUI.LaunchWordingTest do
  # Sentences the screen says that promised a way forward that was not
  # there.
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.TUI
  alias Lemieux.TUI.Notices
  alias Lemieux.TUI.Updates

  describe "skipping the provider panel" do
    defp row(id, fields \\ []),
      do:
        Map.merge(
          %{
            id: id,
            label: id,
            env: String.upcase(id) <> "_API_KEY",
            model: id <> ":m",
            credential: :missing
          },
          Map.new(fields)
        )

    defp skipped(providers) do
      [id: "01SKIP", model: "test:model", test_mode: {80, 24}]
      |> Keyword.put(:first_run, %{providers: providers, config_path: nil})
      |> TUI.new()
      |> sized()
      |> TUI.FirstRun.open()
      |> press("esc")
      |> unwrapped()
    end

    # "/provider and /model choose one later": neither does. `/provider`
    # saves no key, and in a keyless start no provider has one to switch to.
    test "with no key anywhere, it says how a key is added, and offers no switch" do
      text = skipped([row("anthropic"), row("openai")])

      assert text =~
               "no key saved · set one in your environment, or paste it here at the next start"

      refute text =~ "choose one later"
      refute text =~ "/provider"
    end

    test "a row that needs no key is named with the /provider that switches to it" do
      local = row("ollama", key?: false, env: nil, credential: :not_required)
      keyed = row("openai", credential: :present)

      text = skipped([row("anthropic"), keyed, local])

      assert text =~ "/provider openai or /provider ollama works now"
    end
  end

  # An lmx unpacked by hand installs nothing itself. "Use the Unix
  # installer" read as some other installer on macOS, which is Unix too.
  test "an unpacked install says install.sh is what updates itself" do
    host = %{
      tasks: start_supervised!(Task.Supervisor),
      auto?: false,
      check: fn -> :current end,
      stage: fn _info -> {:error, :manual_install} end,
      apply: fn _staged, _app -> {:error, :manual_install} end
    }

    state =
      [test_mode: {80, 24}, id: "unpacked", model: "test:model", updates: host]
      |> TUI.new()
      |> put_in([Access.key!(:status), :update, :phase], :stage)
      |> Updates.result({:error, :manual_install})

    assert %{kind: :info, text: notice} = state |> Notices.items() |> List.last()
    assert notice =~ "install lmx with install.sh to get automatic updates"
    assert notice =~ "On macOS and Linux"
    refute notice =~ "Unix installer"
  end
end
