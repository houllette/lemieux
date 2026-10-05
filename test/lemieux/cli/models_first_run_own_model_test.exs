defmodule Lemieux.CLI.ModelsFirstRunOwnModelTest do
  # The provider panel's row for a model the person chose carries that
  # model, not the table's (`Lemieux.CLI.Models.first_run/2`). It used to
  # carry the table's, and saving a key there moved the session to it and
  # wrote it over the person's `"model"`.
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

  defp chose(dir, model, source, fields \\ []) do
    options = struct!(%Options{model: model}, fields)
    options = put_in(options.host.state_dir, dir)
    put_in(options.host.model_source, source)
  end

  defp row(panel, id), do: Enum.find(panel.providers, &(&1.id == id))

  test "a named model that is not the table's is the one its provider's row carries",
       %{tmp_dir: dir} do
    panel = Models.first_run(chose(dir, "openai:gpt-4.1-mini", :config), no_daemon())

    assert panel.selected == "openai"
    assert panel.intro =~ "No API key was found for openai:gpt-4.1-mini"
    assert %{model: "openai:gpt-4.1-mini", own?: true} = row(panel, "openai")

    # Only the chosen provider's row changes.
    assert %{model: "anthropic:claude-sonnet-5"} = anthropic = row(panel, "anthropic")
    refute Map.get(anthropic, :own?, false)
  end

  test "a resumed session's provider row carries its transcript's model", %{tmp_dir: dir} do
    options = chose(dir, "xai:grok-3", :credential, resume: "01RESUMED")
    panel = Models.first_run(options, no_daemon())

    assert panel.selected == "xai"
    assert %{model: "xai:grok-3", own?: true} = row(panel, "xai")
  end

  # The intro said "Paste one" with nowhere to paste it.
  test "a named provider the table has no row for gets one, first and selected",
       %{tmp_dir: dir} do
    model = "groq:llama-3.3-70b-versatile"
    panel = Models.first_run(chose(dir, model, :flag), no_daemon())

    assert panel.selected == "groq"
    assert panel.intro =~ "Paste one"

    assert [first | _rest] = panel.providers
    assert %{id: "groq", model: ^model, own?: true, env: "GROQ_API_KEY"} = first
    assert first.credential == :missing
  end

  test "a guess nobody chose leaves every row as the table has it", %{tmp_dir: dir} do
    panel = Models.first_run(chose(dir, Options.default_model(), :fallback), no_daemon())

    assert panel.selected == nil
    refute Enum.any?(panel.providers, &Map.get(&1, :own?, false))
  end
end
