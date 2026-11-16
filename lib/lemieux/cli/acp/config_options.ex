defmodule Lemieux.CLI.ACP.ConfigOptions do
  @moduledoc false

  alias Lemieux.Session

  @spec list(session :: pid(), version :: 1 | 2) :: [map()]
  def list(session, version \\ 1) do
    info = Session.info(session)

    models =
      session
      |> Session.available_providers()
      |> Enum.flat_map(&Session.available_models(session, &1))
      |> then(&Enum.uniq([info.model | &1]))

    options =
      [select("model", "Model", "model", info.model, models)] ++
        reasoning(info.reasoning_effort, info.reasoning_efforts)

    if version == 2,
      do:
        Enum.map(options, fn option ->
          option |> Map.put("configId", option["id"]) |> Map.delete("id")
        end),
      else: options
  end

  @spec set(session :: pid(), params :: map(), version :: 1 | 2) :: :ok | {:error, term()}
  def set(session, %{"configId" => id, "value" => value} = params, version)
      when is_binary(value) do
    option = Enum.find(list(session), &(&1["id"] == id))

    with true <- version == 1 or params["type"] == "id",
         %{} <- option,
         true <- Enum.any?(option["options"], &(&1["value"] == value)),
         {:ok, _value} <- change(session, id, value) do
      :ok
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  def set(_session, _params, _version), do: {:error, :invalid_configuration}

  defp change(session, "model", value), do: Session.set_model(session, value)

  defp change(session, "reasoning_effort", value),
    do: Session.set_reasoning_effort(session, value)

  defp reasoning(_current, []), do: []

  defp reasoning(current, efforts),
    do: [
      select(
        "reasoning_effort",
        "Reasoning",
        "thought_level",
        current || "default",
        Enum.uniq(["default" | efforts])
      )
    ]

  defp select(id, name, category, current, values) do
    %{
      "id" => id,
      "name" => name,
      "category" => category,
      "type" => "select",
      "currentValue" => current,
      "options" => Enum.map(values, &%{"value" => &1, "name" => &1})
    }
  end
end
