defmodule Lemieux.CLI.Learning.Observation do
  @moduledoc false
  alias Lemieux.Contract
  alias Lemieux.Extensions.Capture
  alias Lemieux.Learning.Experience.Lessons
  alias Lemieux.Learning.Refinement

  # Ordinary tasks have no capability to read the host's private evidence
  # directory. Release a small verified observation after retrieval commits
  # exposure; do not advertise an inaccessible proposer-workspace file.
  @spec project(store :: Lessons.t(), notes :: [map()]) :: {:ok, [map()]} | {:error, term()}
  def project(store, notes) do
    Enum.reduce_while(notes, {:ok, []}, fn note, {:ok, projected} ->
      with {:ok, lesson} <- Lessons.read(store, note["id"]),
           true <- lesson.sha256 == note["sha256"],
           [encoded] <- Map.values(lesson.artifacts),
           {:ok, bytes} <- Base.decode64(encoded),
           {:ok, record} <- Contract.decode(bytes),
           {:ok, observation} <- observation(record, lesson) do
        view = note |> Map.delete("evidence_file") |> Map.put("source_observation", observation)
        {:cont, {:ok, projected ++ [view]}}
      else
        _unavailable -> {:halt, {:error, :learning_observation_unavailable}}
      end
    end)
  end

  defp observation(record, %{provenance: %{"capture_sha256" => digest}} = lesson) do
    with :ok <- Capture.verify(record),
         true <- record["scope"] == lesson.scope and record["sha256"] == digest do
      {:ok,
       Map.take(record, ~w(kind task_correctness sha256))
       |> Map.put("command", excerpt(record["command"]))
       |> Map.put(
         "observed_exit_statuses",
         record["observations"] |> Enum.take(8) |> Enum.map(& &1["exit_status"])
       )}
    end
  end

  defp observation(record, %{provenance: %{"refinement_sha256" => digest}}) do
    with :ok <- Refinement.verify(record), true <- record["sha256"] == digest do
      {:ok,
       %{
         "kind" => "task_local_refinement",
         "sha256" => digest,
         "task_correctness" => "unassessed",
         "transfer" => "unassessed",
         "decision" => record["decision"]
       }}
    end
  end

  defp observation(_record, _lesson), do: {:error, :unsupported_observation}

  defp excerpt(nil), do: nil

  defp excerpt(command),
    do: command |> String.slice(0, 128) |> String.replace(~r/[\p{Cc}\p{Cf}]/u, " ")
end
