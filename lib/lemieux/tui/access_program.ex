defmodule Lemieux.TUI.AccessProgram do
  @moduledoc "Read-only labels for access options already present in a prepared request."

  @doc "Returns a display label from an ordinary OpenAI request snapshot."
  @spec requested(map()) :: String.t() | nil
  def requested(%{"kind" => "turn", "model" => "openai:" <> _, "params" => params})
      when is_map(params) do
    case params |> Map.get("provider_options") |> programs() do
      %{"cyber" => "standard"} -> "Standard"
      %{"cyber" => "daybreak_blue"} -> "Daybreak Blue"
      %{"cyber" => "daybreak_red"} -> "Daybreak Red"
      _other -> nil
    end
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

  @doc "Restores the latest prepared turn's program when it belongs to the current model."
  @spec restore([Lemieux.Entry.t()], String.t()) :: String.t() | nil
  def restore(entries, model) do
    snapshot =
      entries
      |> Enum.reverse()
      |> Enum.find(fn
        %{type: :request, payload: %{"kind" => "turn"}} -> true
        _entry -> false
      end)

    case snapshot do
      %{payload: %{"model" => ^model} = payload} -> requested(payload)
      _other -> nil
    end
  end

  @doc false
  @spec compact_label(String.t() | nil) :: String.t() | nil
  def compact_label("Daybreak Blue"), do: "DB BLUE REQ"
  def compact_label("Daybreak Red"), do: "DB RED REQ"
  def compact_label("Standard"), do: "ACCESS STD"
  def compact_label(nil), do: nil
end
