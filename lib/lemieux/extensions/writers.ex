defmodule Lemieux.Extensions.Writers do
  @moduledoc """
  Opt-in model-facing writers and task-selection guidance.

  The host supplies `Lemieux.Writers.Tool`'s policy; the model supplies bounded
  briefs. This extension adds no defaults, processes or scheduling authority to
  the core loop. Ordinary tools carry every invocation through host hooks.
  Reapply current host configuration on resume; documents never restore it.
  """
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Writers.Tool, as: WriterTool

  @impl true
  @spec init(opts :: keyword()) :: {:ok, WriterTool.t()} | {:error, term()}
  def init(opts), do: WriterTool.new(opts)

  @impl true
  def apply(harness, tool) do
    if Enum.any?(harness.tools || [], &(Tool.name(&1) == "writers")) do
      harness
    else
      scouts? = Enum.any?(harness.tools || [], &(Tool.name(&1) == "subagents"))

      harness
      |> Harness.update_tools(&(&1 ++ [tool]))
      |> Harness.update_system(fn system ->
        Enum.join(Enum.reject([system, guidance(scouts?)], &is_nil/1), "\n\n")
      end)
    end
  end

  @impl true
  def describe(tool) do
    %{
      "paths" => tool.paths,
      "tools" => tool.tools,
      "max_writers" => tool.max_writers,
      "max_active" => tool.options[:max_active],
      "max_batches" => tool.max_batches,
      "fresh_workspace_per_batch" => is_function(tool.workspace_factory, 1),
      "max_requests_per_writer" => tool.max_requests
    }
  end

  defp guidance(scouts?) do
    scouts =
      if scouts?,
        do:
          "Read-only scouts: use subagents for independent investigations that resolve broad uncertainty before you implement, such as compatibility, persistence and migration impacts. Briefing and duplicated reading cost tokens; a few reads belong here.\n",
        else: ""

    """
    For substantial work, choose a method based on coupling and uncertainty.
    Task size alone does not justify delegation. Default to working directly.
    Single session: shared files or evolving interfaces need one context; e.g.
    redesign retry behavior across the session lifecycle here.
    #{scouts}Serial writers: isolated independent patches can run one at a time when
    provider capacity is constrained; e.g. two adapters with one backend slot.
    Parallel writers: substantial independent patches need stable interfaces and
    disjoint file/test ownership; e.g. CSV and JSONL importers against an agreed
    ingestion contract, with shared wiring owned here. Use only the concurrency
    the host permits. These are heuristics, not proven performance advantages.
    Serial writers in one batch use the same base snapshot: later writers do not
    receive earlier changes. Dependent stages require separately integrated
    batches with fresh snapshots. Close a settled batch before starting another.
    Before delegation, state a short reason, scopes, interfaces and required
    checks. Include briefing, duplicated context, review, integration and failed
    attempts in the expected cost. Keep planning brief. When benefit is unclear,
    scopes overlap, interfaces are unsettled or budget is insufficient, work
    directly or investigate first. Review retained patches and complete reports,
    preserve critical findings, then explicitly accept artifact digests. A model
    completion claim is not verification. Failed work must be inspected before
    replanning; do not silently repeat a failed batch.
    """
  end
end
