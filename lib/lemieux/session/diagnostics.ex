defmodule Lemieux.Session.Diagnostics do
  @moduledoc false
  alias Lemieux.Diagnostic
  alias Lemieux.Session.Core

  def observe(state, entry) do
    case Diagnostic.from_payload(entry.payload) do
      nil ->
        state

      diagnostic ->
        %{state | internal_errors: Map.put(state.internal_errors, diagnostic["id"], entry.id)}
    end
  end

  def finish(%{internal_errors: errors} = state) when map_size(errors) == 0, do: state

  def finish(state) do
    errors = state.internal_errors

    %{state | internal_errors: %{}}
    |> Core.append(
      {:extension_state,
       %{
         "namespace" => "lemieux.errors",
         "value" => %{
           "status" => "turn_summary",
           "count" => map_size(errors),
           "error_ids" => Enum.sort(Map.keys(errors))
         }
       }, nil}
    )
  end

  def child(state, {:subagent, path, {:entry, entry}} = event) do
    case Diagnostic.from_payload(entry.payload) do
      nil ->
        Core.emit(state, event)

      diagnostic ->
        if not current_child?(state, path) or
             Map.has_key?(state.internal_errors, diagnostic["id"]),
           do: state,
           else:
             Core.append(
               state,
               {:error, %{"reason" => Diagnostic.message(diagnostic), "diagnostic" => diagnostic},
                nil}
             )
    end
  end

  def child(state, event), do: Core.emit(state, event)

  defp current_child?(%{evidence: %{current_run: %{start_seq: start}}} = state, [_root, child | _]) do
    Enum.any?(state.reversed_entries, fn entry ->
      entry.seq >= start and entry.type == :subagent_spawn and entry.payload["child_id"] == child
    end)
  end

  defp current_child?(_state, _path), do: false
end
