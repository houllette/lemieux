defmodule Lemieux.CLI.Learning.Retention do
  @moduledoc """
  Workspace cleanup for the first-party host's captures and recalled content.

  The operation claim excludes prepare/retain/refinement workers, and capture's
  own claim excludes a checkpoint writer. A cutoff prevents terminal delivery
  from re-importing an older prompt after deletion. Lesson tombstones, exposure
  receipts, transcripts and refinement accounting stay intact: forgetting text
  must not refund requests, erase an unknown charge or authorize replay.

  Experimental refinement archives can contain source and remain available for
  accounting review. This is retention of captures and recalled guidance, not
  deletion of all copies of a session. Backups and separately exported assets
  are the owner's responsibility.
  """

  alias Lemieux.CLI.Learning.Journal
  alias Lemieux.Extensions.Capture
  alias Lemieux.Extensions.Capture.Storage
  alias Lemieux.Learning.Experience.Lessons
  alias Lemieux.Learning.Experience.Lessons.File, as: LessonFiles

  @spec forget(home :: Path.t(), cwd :: Path.t(), root :: Path.t()) :: :ok | {:error, term()}
  def forget(home, cwd, root) do
    Journal.operation(root, fn ->
      Journal.update(root, fn control -> forget_control(home, cwd, root, control) end)
    end)
  end

  defp forget_control(home, cwd, root, control) do
    store = LessonFiles.new(Path.join(root, "lessons"), Storage.scope(cwd))
    capture = Path.join(home, "capture")

    with {:ok, history} <- Lessons.history(store),
         {:ok, files} <- application_files(root),
         :ok <- Storage.ancestors(Storage.directory(capture, Storage.scope(cwd))),
         :ok <- Capture.forget(capture, cwd),
         :ok <- prune(store, history),
         :ok <- remove_files(files) do
      ids = Enum.map(history, & &1["id"])

      receipt =
        Journal.seal(%{
          "action" => "forget",
          "prior_sha256" => get_in(control, ["last", "sha256"]),
          "at" => DateTime.to_iso8601(DateTime.utc_now()),
          "learning_requests" => get_in(control, ["last", "learning_requests"]),
          "accounting" => get_in(control, ["last", "accounting"]),
          "forgotten_lessons" => length(ids),
          "retained_audit" => true
        })

      {:ok,
       control
       |> Map.put("blocked", Enum.uniq(control["blocked"] ++ ids))
       |> Map.put("last", receipt)}
    end
  end

  defp application_files(root) do
    with {:ok, names} <- File.ls(root) do
      paths =
        names
        |> Enum.filter(&String.starts_with?(&1, ["binding-", "application-"]))
        |> Enum.map(&Path.join(root, &1))

      if Enum.all?(paths, &match?({:ok, %{type: :regular}}, File.lstat(&1))),
        do: {:ok, paths},
        else: {:error, :unsafe_learning_path}
    end
  end

  defp prune(store, history) do
    history
    |> Enum.reject(&(&1["status"] == "pruned"))
    |> Enum.reduce_while(:ok, fn item, :ok ->
      result = Lessons.prune(store, item["id"], "workspace_forget", DateTime.utc_now())
      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp remove_files(paths) do
    Enum.reduce_while(paths, :ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
