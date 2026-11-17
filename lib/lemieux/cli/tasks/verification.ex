defmodule Lemieux.CLI.Tasks.Verification do
  @moduledoc false
  alias Lemieux.CLI.Tasks.Activity
  alias Lemieux.Extensions.Verify.Work

  @spec rows(info :: map()) :: [map()]
  def rows(info) do
    Enum.map(Work.list(info.supervisor, info.id), fn work ->
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
        status: result["status"] || "running",
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
end
