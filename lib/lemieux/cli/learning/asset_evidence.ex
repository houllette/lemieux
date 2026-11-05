defmodule Lemieux.CLI.Learning.AssetEvidence do
  @moduledoc """
  Observed use of exact selected asset bytes in the effective task harness.

  A proposal, approval or activation counter alone cannot qualify a kind. A
  selected candidate must appear in a verified harness snapshot and its intended
  surface must actually be used. An unrelated pre-existing skill or a successful
  profile search cannot supply evidence for a new learned asset kind. The host
  separately verifies complete transcripts, accounting and behavioral outcomes.
  """
  alias Lemieux.Harness.Snapshot

  @kinds ~w(skill configuration tool_description)

  @doc "Returns observed selected digests per kind, withholding unrestored or unused assets."
  @spec observed(evidence :: map()) :: %{String.t() => [String.t()]}
  def observed(evidence) do
    candidates = get_in(evidence, ["asset_search", "candidates"]) || []
    application = evidence["asset_application"] || %{}
    selected = application["asset_sha256"] || []
    snapshots = snapshots(evidence["selected"])

    Map.new(@kinds, fn kind ->
      digests =
        for %{"asset" => asset} <- candidates,
            get_in(asset, ["content", "kind"]) == kind,
            application["restored"] == true,
            asset["sha256"] in selected,
            Enum.any?(snapshots, &bound?(&1, asset)),
            used?(kind, asset, evidence, snapshots),
            do: asset["sha256"]

      {kind, Enum.uniq(digests)}
    end)
  end

  defp bound?(snapshot, asset),
    do:
      Enum.any?(snapshot["resolved_assets"], fn resolved ->
        resolved["sha256"] == asset["sha256"] and resolved["id"] == asset["id"] and
          resolved["kind"] == asset["content"]["kind"]
      end)

  defp used?("skill", asset, evidence, _snapshots) do
    name = get_in(asset, ["content", "payload", "name"])

    Enum.any?(results(evidence), fn result ->
      result["name"] == "skill" and result["arguments"]["name"] == name and
        result["arguments"]["file"] in [nil, "SKILL.md"]
    end)
  end

  defp used?("tool_description", asset, evidence, snapshots) do
    descriptions = asset["content"]["payload"]
    original = snapshots(evidence["original"])

    Enum.all?(descriptions, fn {name, description} ->
      Enum.any?(snapshots, &(bound?(&1, asset) and description(&1, name) == description)) and
        Enum.any?(original, &(description(&1, name) != description))
    end) and Enum.any?(results(evidence), &Map.has_key?(descriptions, &1["name"]))
  end

  defp used?("configuration", asset, evidence, _snapshots) do
    count = get_in(asset, ["content", "payload", "glob_after_requests"])
    catalog = glob_catalog(evidence["selected"])

    catalog != [] and catalog != glob_catalog(evidence["original"]) and
      Enum.all?(Enum.with_index(catalog), fn {visible, index} -> visible == index >= count end)
  end

  defp description(snapshot, name),
    do:
      Enum.find_value(snapshot["tools"]["descriptors"], fn tool ->
        if tool["name"] == name, do: tool["description"]
      end)

  defp snapshots(observation) do
    for %{"type" => "harness_snapshot", "payload" => payload} <- transcript(observation),
        {:ok, snapshot} <- [Snapshot.new(payload)],
        do: Snapshot.to_map(snapshot)
  end

  defp results(evidence) do
    for %{"type" => "tool_result", "payload" => result} <- transcript(evidence["selected"]),
        result["error"] == false,
        do: result
  end

  defp glob_catalog(observation) do
    for %{"type" => "request", "payload" => request} <- transcript(observation),
        do: Enum.any?(request["catalog"]["per_tool"], &(&1["name"] == "glob"))
  end

  defp transcript(%{"transcript" => entries}) when is_list(entries), do: entries
  defp transcript(_missing), do: []
end
