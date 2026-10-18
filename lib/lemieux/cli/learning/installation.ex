defmodule Lemieux.CLI.Learning.Installation do
  @moduledoc false
  alias Lemieux.Contract

  # Reference process-crash protocol for an external runtime pointer. The host
  # serializes calls and blocks serving until recover/3 succeeds on restart.
  # Only opaque version references and audit data are persisted, never executable
  # harnesses or authority. File sync + rename is not power-loss certification.
  @spec run(
          path :: Path.t(),
          prior :: map(),
          target :: map(),
          receipt :: map(),
          install :: function(),
          check :: function()
        ) :: term()
  def run(path, prior, target, receipt, install, check) do
    intent =
      seal(%{
        "state" => "intent",
        "prior" => prior,
        "target" => target,
        "receipt_sha256" => receipt["sha256"]
      })

    with false <- File.exists?(path),
         :ok <- write(path, intent),
         :ok <- install.(target),
         :ok <- check.(),
         :ok <- write(path, seal(Map.put(Map.delete(intent, "sha256"), "state", "committed"))) do
      :ok
    else
      true -> {:error, :installation_requires_recovery}
      error -> rollback(path, prior, install, error)
    end
  end

  @spec recover(path :: Path.t(), install :: function(), fresh_authority :: function()) :: term()
  def recover(path, install, fresh_authority) do
    with {:ok, bytes} <- File.read(path),
         {:ok, record} <- Contract.decode(bytes),
         :ok <- Contract.verify_digest(record, "sha256"),
         :ok <- fresh_authority.(),
         :ok <- install.(record["prior"]),
         :ok <- write(path, seal(record |> Map.delete("sha256") |> Map.put("state", "restored"))) do
      {:ok, record["prior"]}
    else
      _unknown -> {:error, :installation_recovery_blocked}
    end
  end

  defp rollback(path, prior, install, error) do
    with true <- File.exists?(path),
         {:ok, ^prior} <- recover(path, install, fn -> :ok end) do
      {:error, {:installation_rolled_back, error}}
    else
      _unknown -> {:error, :installation_recovery_blocked}
    end
  end

  @spec write(path :: Path.t(), record :: map()) :: :ok | {:error, term()}
  def write(path, record) do
    temporary = path <> "." <> Lemieux.ID.generate() <> ".tmp"

    try do
      with :ok <- File.mkdir_p(Path.dirname(path)),
           {:ok, file} <- :file.open(String.to_charlist(temporary), [:write, :binary, :exclusive]),
           :ok <- persist(file, Contract.encode!(record)) do
        File.rename(temporary, path)
      end
    after
      File.rm(temporary)
    end
  end

  defp persist(file, bytes) do
    with :ok <- :file.write(file, bytes), do: :file.sync(file)
  after
    :file.close(file)
  end

  defp seal(map), do: Map.put(map, "sha256", Contract.digest(map))
end
