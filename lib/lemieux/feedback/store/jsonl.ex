defmodule Lemieux.Feedback.Store.JSONL do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Local append-only JSONL feedback storage, one file per feedback id.

  Each line is a complete `Lemieux.Feedback` revision. Before append, the
  existing history is checked so revision numbers cannot skip and immutable
  raw text/provenance cannot be rewritten. The implementation has no process;
  standalone capture is one writer, while database hosts provide their own
  transactional implementation.
  """

  @behaviour Lemieux.Feedback.Store

  alias Lemieux.Feedback

  @extension ".jsonl"
  @valid_id ~r/\Afb_[A-Za-z0-9_-]+\z/

  @doc "Builds a feedback store rooted at `dir`."
  @spec new(dir :: Path.t()) :: Lemieux.Feedback.Store.t()
  def new(dir) when is_binary(dir), do: {__MODULE__, %{dir: dir}}

  @impl Lemieux.Feedback.Store
  def append(state, %Feedback{} = feedback) do
    with {:ok, path} <- path(state, feedback.id),
         {:ok, revisions} <- existing(path),
         :ok <- validate_append(revisions, feedback),
         :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, [Feedback.encode!(feedback), ?\n], [:append])
    end
  rescue
    error -> {:error, {:unreadable, feedback.id, Exception.message(error)}}
  end

  @impl Lemieux.Feedback.Store
  def read(state, id) do
    with {:ok, path} <- path(state, id),
         {:ok, contents} <- File.read(path) do
      decode(contents)
    else
      {:error, :enoent} -> {:error, :not_found}
      error -> error
    end
  rescue
    error -> {:error, {:unreadable, id, Exception.message(error)}}
  end

  @impl Lemieux.Feedback.Store
  def list_feedback(%{dir: dir}) do
    ids =
      dir
      |> Path.join("fb_*" <> @extension)
      |> Path.wildcard()
      |> Enum.map(&Path.basename(&1, @extension))
      |> Enum.sort()

    {:ok, ids}
  end

  defp existing(path) do
    case File.read(path) do
      {:ok, contents} -> decode(contents)
      {:error, :enoent} -> {:ok, []}
      error -> error
    end
  end

  defp decode(contents) do
    revisions =
      contents
      |> String.split("\n", trim: true)
      |> Enum.map(&Feedback.decode!/1)

    {:ok, revisions}
  end

  defp validate_append([], %Feedback{revision: 1}), do: :ok
  defp validate_append([], %Feedback{}), do: {:error, :first_revision_must_be_one}

  defp validate_append(revisions, %Feedback{} = next) do
    latest = List.last(revisions)

    cond do
      latest.raw_text != next.raw_text -> {:error, :raw_text_changed}
      latest.provenance != next.provenance -> {:error, :provenance_changed}
      next.revision != latest.revision + 1 -> {:error, :non_sequential_revision}
      true -> :ok
    end
  end

  defp path(%{dir: dir}, id) when is_binary(id) do
    if Regex.match?(@valid_id, id),
      do: {:ok, Path.join(dir, id <> @extension)},
      else: {:error, {:invalid_feedback_id, id}}
  end
end
