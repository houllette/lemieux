defmodule Lemieux.CLI.ACP.ConfigOptionsTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.ACP.ConfigOptions
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defmodule Provider do
    def available_models(_state, _opts), do: ["test:first", "test:second"]
    def reasoning_efforts(_state, _model), do: ["low", "high"]
    def validate_model(_state, model, _tools) when model in ["test:first", "test:second"], do: :ok
    def validate_model(_state, _model, _tools), do: {:error, :unsupported_model}
  end

  test "standard model and reasoning changes persist and stay within offered values", %{
    tmp_dir: dir
  } do
    runtime = :"acp_catalog_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    store = JSONL.new(Path.join(dir, "sessions"))

    opts = [
      supervisor: runtime,
      provider: {Provider, nil},
      store: store,
      cwd: dir,
      tools: [],
      model: "test:first"
    ]

    assert {:ok, session} = Lemieux.start_session(opts)
    id = Session.info(session).id

    options = ConfigOptions.list(session)
    assert Enum.find(options, &(&1["id"] == "reasoning_effort"))["currentValue"] == "default"
    assert :ok = ConfigOptions.set(session, %{"configId" => "model", "value" => "test:second"}, 1)

    assert :ok =
             ConfigOptions.set(
               session,
               %{"configId" => "reasoning_effort", "value" => "high", "type" => "id"},
               2
             )

    assert {:error, _} =
             ConfigOptions.set(
               session,
               %{"configId" => "reasoning_effort", "value" => "unsupported"},
               1
             )

    assert {:error, _} =
             ConfigOptions.set(
               session,
               %{"configId" => "model", "value" => "test:first", "type" => "boolean"},
               2
             )

    assert Session.info(session).model == "test:second"
    assert Session.info(session).reasoning_effort == "high"

    GenServer.stop(session)

    assert {:ok, restored} =
             Lemieux.resume_session(opts |> Keyword.delete(:model) |> Keyword.put(:resume, id))

    restored_options = ConfigOptions.list(restored, 2)

    assert Enum.find(restored_options, &(&1["configId"] == "model"))["currentValue"] ==
             "test:second"

    assert Enum.find(restored_options, &(&1["configId"] == "reasoning_effort"))["currentValue"] ==
             "high"

    GenServer.stop(restored)
  end
end
