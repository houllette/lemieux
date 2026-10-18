defmodule Lemieux.CLI.Learning.Leases do
  @moduledoc false
  @behaviour Lemieux.Learning.Refinement.Isolation
  alias Lemieux.Benchmark.WorkspaceSnapshot
  alias Lemieux.CLI.Runtime.Evaluation
  alias Lemieux.Contract

  @impl true
  def inspect(config) do
    with {:ok, snapshot} <- WorkspaceSnapshot.capture(config.task.cwd) do
      {:ok,
       %{
         "isolated" => config.isolated,
         "clean" => digest(snapshot) == config.source_sha256,
         "bindings" => config.bindings,
         "effects" => ["read", "workspace_write"]
       }}
    end
  end

  @impl true
  def acquire(config, id, bindings) do
    cwd = Path.join(config.root, id)

    with {:ok, _} <- File.cp_r(config.task.cwd, cwd),
         {:ok, prepared} <-
           Evaluation.prepare(config.options, Keyword.put(config.host, :cwd, cwd),
             surface: config.surface
           ) do
      {:ok,
       %{
         id: id,
         bindings: bindings,
         runtime_identity: Evaluation.identity(prepared),
         task: %{config.task | cwd: cwd},
         session: []
       }}
    end
  end

  @impl true
  def validate(config, lease, bindings) do
    with {:ok, %{"clean" => true}} <- __MODULE__.inspect(config),
         true <- lease.bindings == bindings and bindings == config.bindings,
         true <- Path.dirname(lease.task.cwd) == config.root do
      :ok
    else
      _invalid -> {:error, :lease_inputs_changed}
    end
  end

  @impl true
  def release(_config, lease), do: remove(lease.task.cwd)
  @impl true
  def abort(config, id), do: remove(Path.join(config.root, id))

  @spec source_digest(root :: Path.t()) :: {:ok, String.t()} | {:error, term()}
  def source_digest(root) do
    with {:ok, snapshot} <- WorkspaceSnapshot.capture(root), do: {:ok, digest(snapshot)}
  end

  defp digest(snapshot),
    do: snapshot |> :erlang.term_to_binary([:deterministic]) |> Contract.sha256()

  defp remove(path) do
    case File.rm_rf(path) do
      {:ok, _} -> :ok
      {:error, reason, _} -> {:error, reason}
    end
  end
end
