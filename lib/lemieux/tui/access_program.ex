defmodule Lemieux.TUI.AccessProgram do
  @moduledoc "Labels for prepared request options and access confirmed by the provider."

  @doc "Returns a display label from an ordinary OpenAI request snapshot."
  @spec requested(map()) :: String.t() | nil
  def requested(%{"kind" => "turn", "model" => "openai:" <> _, "params" => params})
      when is_map(params) do
    if params["standard_access"] == true,
      do: label("standard"),
      else: params |> Map.get("provider_options") |> programs() |> label_program()
  end

  def requested(_snapshot), do: nil

  defp programs(%{"access_programs" => programs}), do: programs

  defp programs(options) when is_list(options) do
    Enum.find_value(options, fn
      ["access_programs", programs] -> programs
      _option -> nil
    end)
  end

  defp programs(_options), do: nil

  defp label_program(%{"cyber" => program}), do: label(program)
  defp label_program(_other), do: nil

  defp label("standard"), do: "Standard"
  defp label("daybreak_blue"), do: "Daybreak Blue"
  defp label("daybreak_red"), do: "Daybreak Red"
  defp label(_other), do: nil

  @doc "Reads an explicit confirmation from the completed assistant entry for this request."
  @spec confirmed(map(), String.t() | nil) :: String.t() | nil
  def confirmed(%{"request_id" => id} = payload, id) when is_binary(id) do
    if payload["partial"] != true, do: label(payload["confirmed_access_program"])
  end

  def confirmed(_payload, _id), do: nil

  @doc "Restores the latest prepared turn and its matching confirmation for the current model."
  @spec restore([Lemieux.Entry.t()], String.t()) :: map()
  def restore(entries, model) do
    {later, snapshots} =
      entries
      |> Enum.reverse()
      |> Enum.split_while(&(not turn_request?(&1)))

    case {snapshots, Enum.any?(later, &other_model_config?(&1, model))} do
      {[%{payload: %{"model" => ^model} = payload} | _earlier], false} ->
        request_id = payload["id"]

        confirmation =
          Enum.find_value(later, fn
            %{type: :assistant, payload: answer} -> confirmed(answer, request_id)
            _entry -> nil
          end)

        %{
          requested_access_program: requested(payload),
          access_request_id: request_id,
          confirmed_access_program: confirmation
        }

      _other ->
        %{requested_access_program: nil, access_request_id: nil, confirmed_access_program: nil}
    end
  end

  defp turn_request?(%{type: :request, payload: %{"kind" => "turn"}}), do: true
  defp turn_request?(_entry), do: false

  defp other_model_config?(%{type: :session, payload: %{"model" => selected}}, model),
    do: selected != model

  defp other_model_config?(_entry, _model), do: false

  @doc false
  @spec compact_label(String.t() | nil) :: String.t() | nil
  def compact_label("Daybreak Blue"), do: "DB BLUE"
  def compact_label("Daybreak Red"), do: "DB RED"
  def compact_label("Standard"), do: "STD"
  def compact_label(nil), do: nil
end
