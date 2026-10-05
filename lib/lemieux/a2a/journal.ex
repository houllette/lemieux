defmodule Lemieux.A2A.Journal do
  @moduledoc """
  Optional, private task projection and admission ledger. Sessions retain their
  ordinary transcripts; this single-server journal stores ownership and task
  results independently. Atomic replace prevents partial records. A host must
  give each server its own directory and keep it outside the exported tree.
  Recovery fails interrupted executions rather than replaying provider requests.
  """
  @doc """
  Reads the journal in `directory`, creating the directory if needed and
  setting it to mode 0700 either way. `nil` means no journal, and reads as an
  empty one.
  """
  @spec load(directory :: Path.t() | nil) :: {:ok, map()} | {:error, term()}
  def load(nil), do: {:ok, %{"tasks" => [], "admitted" => 0}}

  def load(directory) do
    with :ok <- File.mkdir_p(directory), :ok <- File.chmod(directory, 0o700) do
      case File.read(Path.join(directory, "tasks.json")) do
        {:ok, data} -> JSON.decode(data)
        {:error, :enoent} -> load(nil)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  Replaces the journal in `directory`: a new file (mode 0600) is renamed over
  the old one, so a crash leaves the previous record whole. `nil` saves nothing.
  """
  @spec save(directory :: Path.t() | nil, data :: map()) :: :ok | {:error, term()}
  def save(nil, _data), do: :ok

  def save(directory, data) do
    path = Path.join(directory, "tasks.json")
    temp = path <> "." <> Lemieux.ID.generate()

    with :ok <- File.write(temp, JSON.encode!(data), [:exclusive]),
         :ok <- File.chmod(temp, 0o600),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temp)
        {:error, reason}
    end
  end
end
