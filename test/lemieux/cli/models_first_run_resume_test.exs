defmodule Lemieux.CLI.ModelsFirstRunResumeTest do
  # What the provider panel opens with when the model the terminal UI starts
  # on has no key (`Lemieux.CLI.Models.first_run/2`).
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Models
  alias Lemieux.CLI.Options

  @moduletag :tmp_dir

  defp no_daemon do
    [
      env: %{},
      ollama: [
        get: fn _url, _opts -> {:error, %Req.TransportError{reason: :econnrefused}} end,
        post: fn _url, _opts -> flunk("nothing answered /api/tags, so nothing is described") end
      ]
    ]
  end

  # `lmx --resume ID` and `lmx -c` start on the transcript's model, while
  # `model_source` still says what chose the start model before the
  # transcript replaced it: a guess, when nothing was named. Read alone, it
  # opened the panel on no row, with the newcomer's sentence, for a model
  # somebody had chosen when that session began.
  test "a resumed session's provider is preselected, and its model named", %{tmp_dir: dir} do
    options = %Options{model: "xai:grok-4.7", resume: "01RESUMED"}
    options = put_in(options.host.state_dir, dir)
    options = put_in(options.host.model_source, :credential)

    assert %{selected: "xai", intro: intro} = Models.first_run(options, no_daemon())
    assert intro =~ "No API key was found for xai:grok-4.7"
  end

  test "the same guess without a transcript selects nothing", %{tmp_dir: dir} do
    options = %Options{model: Options.default_model()}
    options = put_in(options.host.state_dir, dir)

    assert %{selected: nil, intro: nil} = Models.first_run(options, no_daemon())
  end

  # `/model` chooses within the current provider: on the placeholder,
  # `/model ollama:TAG` asked for `anthropic:ollama:TAG`, which a keyless
  # sitting refused with the same missing key.
  test "under --config none the way to a local model is /provider ollama" do
    assert {:ok, hermetic} = Options.parse(["--config", "none"])
    assert %{hint: hint} = Models.first_run(hermetic, env: %{})

    assert hint =~ "/provider ollama"
    refute hint =~ "/model ollama:"
    assert hint =~ "set OLLAMA_CONTEXT_LENGTH to 32768 or more (65536 recommended)"
  end
end
