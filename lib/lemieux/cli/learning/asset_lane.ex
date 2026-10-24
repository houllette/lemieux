defmodule Lemieux.CLI.Learning.AssetLane do
  @moduledoc """
  Task-local research over independently reviewed typed assets.

  Selected versions are retained through `Lemieux.Learning.Asset.Source` before
  activation. The compact search receipt contains content identities, but lacks
  creation metadata needed to reconstruct the original complete Version for
  export. Archiving while that Version is still available preserves it without
  inventing historical timestamps. These sources carry no receiving-host
  approval or qualification; a failed archive withholds activation.
  """
  alias Lemieux.CLI.Learning.AssetSearch
  alias Lemieux.CLI.Learning.Installation
  alias Lemieux.CLI.Learning.Leases
  alias Lemieux.CLI.Learning.QualificationHost
  alias Lemieux.CLI.Learning.Reflection
  alias Lemieux.CLI.Runtime.Evaluation
  alias Lemieux.Learning.Asset
  alias Lemieux.Learning.Asset.Source
  alias Lemieux.Learning.Discovery.ProfileDelta
  alias Lemieux.Learning.Refinement
  alias Lemieux.Tool

  @spec run(config :: map(), details :: map(), attempt :: function(), choose :: function()) ::
          map()
  def run(config, details, attempt, choose) do
    context = context(config, details)
    root = Path.join(details.dir, "asset-search")
    :ok = File.mkdir(root)
    {:ok, approvals} = Agent.start_link(fn -> %{} end)

    authority = fn ->
      if QualificationHost.enabled?(config),
        do: {:ok, %{context | approved_digests: Agent.get(approvals, &Map.keys/1)}},
        else: {:error, :disabled}
    end

    record = %{
      "task_request" => details.fixture.task.prompt,
      "original" => Reflection.project(details.original.observation),
      "selected" => Reflection.project(details.result.selected.observation),
      "public_grades" => %{
        "original" => details.original.grade,
        "selected" => details.result.selected.grade
      },
      "prior_experience" => if(details.retrieved, do: details.retrieved.notes, else: [])
    }

    :ok = Installation.write(Path.join(root, "source.json"), record)

    try do
      outcome =
        AssetSearch.run(record, context,
          controller: details.controller,
          isolation: {Leases, details.lease},
          bindings: details.lease.bindings,
          allocation: allocation(config),
          support_policy: config.support_policy,
          terminal_rule: Map.get(config, :terminal_rule, :completed_task),
          allow_live: config[:allow_live] == true,
          task_model: config.model,
          editor_model: config[:editor_model] || config.model,
          editor_effort: config[:editor_effort] || config.effort,
          provider: config.provider,
          cwd: root,
          sessions_dir: Path.join(details.dir, "sessions"),
          supervisor: config.supervisor,
          token_bound: &QualificationHost.token_bound/1,
          intent: &Installation.write(Path.join(root, "intent.json"), &1),
          approve: fn version, review ->
            with {:ok, _current} <- authority.(),
                 :ok <- Asset.verify(version, context),
                 :ok <-
                   Installation.write(Path.join(root, version.digest <> "-review.json"), review) do
              Agent.update(approvals, &Map.put(&1, version.digest, review))
            end
          end,
          probe: fn assets, child ->
            factory = factory(config, details, assets, root, authority)
            {:ok, attempt.(child, "asset-probe-" <> Lemieux.ID.generate(), factory, :probe)}
          end
        )

      finish(outcome, config, details, root, authority, attempt, choose)
    after
      Agent.stop(approvals)
    end
  end

  defp finish({:ok, receipt, selected}, config, details, root, authority, attempt, choose) do
    :ok = Installation.write(Path.join(root, "receipt.json"), receipt)
    details = %{details | result: Map.put(details.result, :asset_search, receipt)}

    case archive(selected, root, authority) do
      :ok -> apply_selected(selected, config, details, root, authority, attempt, choose)
      error -> finish(error, config, details, root, authority, attempt, choose)
    end
  end

  defp finish(error, _config, details, root, _authority, _attempt, _choose) do
    failure = %{"kind" => "asset_search_incomplete", "reason" => inspect(error)}
    :ok = Installation.write(Path.join(root, "incomplete.json"), failure)
    Map.put(details.result, :learning_failure, failure)
  end

  defp archive([], _root, _authority), do: :ok

  defp archive(selected, root, authority) do
    sources = Path.join(root, "selected-sources")

    with {:ok, context} <- authority.(), :ok <- File.mkdir(sources) do
      Enum.reduce_while(selected, :ok, &archive_item(&1, &2, sources, context))
    end
  end

  defp archive_item(item, :ok, sources, context) do
    case Source.write(item.version, Path.join(sources, item.version.id), context) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp apply_selected(selected, config, details, root, authority, attempt, choose) do
    result = details.result

    if selected == [] do
      result
    else
      final =
        attempt.(
          details.controller,
          "asset-selected",
          factory(config, details, selected, root, authority),
          :task
        )

      case Refinement.preflight({Leases, details.lease}, details.lease.bindings) do
        :ok ->
          application = %{
            "asset_sha256" => Enum.map(selected, & &1.version.digest),
            "restored" => true,
            "final_observation" => final.observation,
            "final_public_grade" => final.grade
          }

          result
          |> Map.put(:asset_application, application)
          |> Map.put(:selected, choose.(final, result.selected))

        _changed ->
          Map.put(result, :learning_failure, %{"kind" => "asset_restoration_incomplete"})
      end
    end
  end

  defp factory(config, details, assets, root, authority) do
    changes = profile_changes(details)

    fn lease ->
      {:ok, prepared} =
        Evaluation.prepare(
          details.lease.options,
          Keyword.put(details.lease.host, :cwd, lease.task.cwd),
          surface: details.lease.surface,
          changes: changes
        )

      {:ok, current} = authority.()

      {:ok, harness} =
        AssetSearch.apply(assets, prepared.harness, current, root, config.environment)

      harness
    end
  end

  defp allocation(config),
    do: %{
      requests: Map.get(config, :asset_requests, 8 * Map.get(config, :task_requests, 16) + 4),
      tokens: Map.get(config, :asset_tokens, 4_500_000),
      time_ms: Map.get(config, :asset_time_ms, 1_500_000),
      cost_usd: nil
    }

  defp profile_changes(%{
         result: %{refinement: %{"decision" => "proposed"} = receipt},
         baseline: baseline
       }) do
    {:ok, changes} = ProfileDelta.changes(baseline, receipt["selected_profile"])
    changes
  end

  defp profile_changes(_details), do: %{}

  defp context(config, details) do
    tools = (details.prepared.harness.tools || []) ++ (details.prepared.harness.host_tools || [])

    %{
      scope: config.scope,
      binding: %{
        "runtime_sha256" => Evaluation.identity(details.prepared)["sha256"],
        "model" => config.model,
        "effort" => config.effort,
        "repository" => config.scope["id"],
        "tools_sha256" => details.lease.bindings["descriptors_sha256"],
        "environment_sha256" => details.lease.bindings["environment_sha256"]
      },
      trust: "personal",
      tools: Enum.map(tools, &Tool.name/1),
      description_tools: ~w(read write edit bash),
      settings_allowlist: ["search.glob_after_requests"],
      helper_extensions: Map.get(config, :asset_helper_extensions, [".py"]),
      allowed_asset_kinds: Map.get(config, :asset_kinds, ["skill", "configuration"]),
      approved_digests: []
    }
  end
end
