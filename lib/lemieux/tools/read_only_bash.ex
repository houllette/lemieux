defmodule Lemieux.Tools.ReadOnlyBash do
  @moduledoc """
  Read-focused shell and Python scripts for delegated investigators.

  Uses Bash's foreground/background lifecycle with a separate read-only OS
  sandbox: no writable workspace, caches or shared temporary roots, no network,
  and the host's credential exclusions remain in force. Scripts are supplied
  inline instead of written into the repository. Missing sandbox support is an
  error, never an unsandboxed fallback. Remote environments require their host
  to supply an equally confined tool rather than executing on the local host.
  """
  @behaviour Lemieux.Tool
  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Tools.Bash

  @impl true
  def name, do: "bash"
  @impl true
  def description do
    "Run read-focused shell/Python scripts inline in a read-only OS sandbox. Workspace, caches and temporary files are not writable; network is disabled. " <>
      "Use python3 -c or a pipeline for analysis. Set background true for long scripts: your bounded host waits for completion without model polling. " <>
      "Supply a brief purpose summary for background work and use its returned player name in replies. Prefer read, grep and glob for ordinary file inspection when available. " <>
      "Do independent reading, then yield. Do not poll or restart background commands."
  end

  @impl true
  def schema, do: Bash.schema()
  @impl true
  def read_only?, do: true
  @impl true
  def parallel_safe?, do: true
  @impl true
  def metadata do
    Bash.metadata()
    |> Map.put(:effects, %{class: "read", resource_types: ["filesystem"]})
  end

  @impl true
  def run(args, context) do
    with {:ok, environment} <- environment(Map.get(context, :environment, Environment.local())) do
      result = Bash.run(args, Map.put(context, :environment, environment))
      started(result, args)
    end
  end

  defp started({:ok, %Lemieux.Tool.Result{} = result}, %{"background" => true}) do
    {:ok,
     %{
       result
       | model_text:
           "Background script started. Its bounded host will wait for completion. Do independent reading, then yield instead of polling."
     }}
  end

  defp started(result, _args), do: result

  @doc "Derives enforced read-only commands while retaining the host's secret exclusions."
  @spec environment(environment :: Environment.t()) ::
          {:ok, Environment.t()} | {:error, String.t()}
  def environment({Sandbox, %Sandbox{} = sandbox}),
    do:
      {:ok,
       {Sandbox, %{sandbox | read_only: true, writable: [], network: false, localhost: false}}}

  def environment({Local, _state} = local), do: Sandbox.new(inner: local, read_only: true)
  def environment(Local), do: Sandbox.new(inner: Local, read_only: true)

  def environment({module, state}) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :read_only_commands, 1),
      do: module.read_only_commands(state),
      else: unsupported()
  end

  def environment(_environment), do: unsupported()

  defp unsupported,
    do: {:error, "This host environment does not provide enforced read-only script execution."}
end
