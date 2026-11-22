defmodule Lemieux.CLI.Tasks.Verification do
  @moduledoc false
  alias Lemieux.CLI.Tasks.Activity
  alias Lemieux.Extensions.Verify.Work
  alias Lemieux.Session

  @spec rows(info :: map()) :: [map()]
  def rows(info) do
    live = Work.list(info.supervisor, info.id)
    context = Session.work_context(info.session, ["lemieux.verify"])

    saved =
      context.entries
      |> Enum.reverse()
      |> Enum.flat_map(&completed_check/1)

    (live ++ saved)
    |> Enum.uniq_by(& &1.id)
    |> Enum.take(256)
    |> Enum.map(fn work ->
      result = work.result || %{}

      row = %{
        id: "verification:" <> work.id,
        work_id: work.id,
        task_id: nil,
        watch_id: nil,
        owner_id: info.id,
        owner_label: nil,
        kind: :verification,
        type_label: "Verification",
        source: "verification",
        name: "Post-answer verification",
        label: work.command,
        description:
          if(work.result == nil,
            do: "Check after the answer; the turn is still active.",
            else: "Post-answer check; retained output."
          ),
        command: work.command,
        logs: work.logs,
        status: status(result),
        running?: work.result == nil,
        watching?: false,
        managed?: true,
        follow_up?: false,
        delivered?: work.result != nil,
        observation: nil,
        target: %{},
        url: nil,
        deadline: nil,
        summary: result["reason"],
        parent_id: nil
      }

      Activity.decorate(
        row,
        %{
          started_at: work.started_at,
          finished_at: result["finished_at"],
          duration_ms: result["duration_ms"] || work.duration_ms
        },
        []
      )
    end)
  end

  defp completed_check(%{
         type: :extension_state,
         payload: %{
           "namespace" => "lemieux.verify",
           "value" => %{"last" => %{"task_id" => id, "status" => status} = result}
         }
       })
       when is_binary(id) and status != "running" do
    [
      %{
        id: id,
        command: result["command"],
        started_at: result["started_at"],
        duration_ms: result["duration_ms"],
        logs: result["output"] || "",
        result: result
      }
    ]
  end

  defp completed_check(_entry), do: []

  defp status(%{"status" => "failed", "exit_status" => exit}) when exit in [126, 127],
    do: "blocked"

  defp status(%{"status" => "failed_to_run"}), do: "unavailable"
  defp status(result), do: result["status"] || "running"
end
