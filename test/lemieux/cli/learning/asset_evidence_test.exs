defmodule Lemieux.CLI.Learning.AssetEvidenceTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.AssetEvidence
  alias Lemieux.Contract
  alias Lemieux.Harness.Snapshot
  alias Lemieux.Request
  alias Lemieux.Tool.Override
  alias Lemieux.Tools.Read

  test "only a selected, snapshot-bound, used and restored procedure counts" do
    asset = asset("skill", %{"name" => "check-records"})
    evidence = evidence(asset, [Read], [result("skill", %{"name" => "check-records"})])
    assert AssetEvidence.observed(evidence)["skill"] == [asset["sha256"]]

    for changed <- [
          put_in(evidence, ["asset_application", "restored"], false),
          put_in(evidence, ["asset_application", "asset_sha256"], []),
          put_in(evidence, ["selected", "transcript"], [
            snapshot([], [Read]),
            result("skill", %{"name" => "check-records"})
          ]),
          put_in(evidence, ["selected", "transcript"], [
            snapshot([asset], [Read]),
            result("skill", %{"name" => "unrelated-personal-skill"})
          ]),
          put_in(evidence, ["selected", "transcript"], [
            snapshot([asset], [Read]),
            result("skill", %{"name" => "check-records", "file" => "references/other.md"})
          ])
        ] do
      assert AssetEvidence.observed(changed)["skill"] == []
    end

    tampered =
      snapshot([asset], [Read])
      |> put_in(["payload", "system_prompt_sha256"], Contract.sha256("changed"))

    assert AssetEvidence.observed(
             put_in(evidence, ["selected", "transcript"], [
               tampered,
               result("skill", %{"name" => "check-records"})
             ])
           )["skill"] == []
  end

  test "tool descriptions must reach a request and a successful call of the affected tool" do
    text = "Inspect current bytes before editing."
    asset = asset("tool_description", %{"read" => text})
    described = Override.new!(Read, description: text)
    evidence = evidence(asset, [described], [result("read", %{"path" => "input"})])
    assert AssetEvidence.observed(evidence)["tool_description"] == [asset["sha256"]]
    unchanged = put_in(evidence, ["original", "transcript"], [snapshot([], [described])])
    assert AssetEvidence.observed(unchanged)["tool_description"] == []
    unused = evidence(asset, [described], [result("write", %{})])
    assert AssetEvidence.observed(unused)["tool_description"] == []
  end

  test "selective skills require an actual complete body while legacy evidence keeps its meaning" do
    asset = asset("skill", %{"name" => "check-records"})
    original = evidence(asset, [Read], [result("skill", %{"name" => "check-records"})])

    selective =
      put_in(original, ["asset_search", "plan"], %{"protocol" => %{"id" => "reviewed_assets/v5"}})

    assert AssetEvidence.observed(original)["skill"] == [asset["sha256"]]
    assert AssetEvidence.observed(selective)["skill"] == []
    read = result("skill", %{"name" => "check-records", "file" => ""})
    read = put_in(read, ["payload", "output"], "Skill: check-records\nComplete body")
    selective = put_in(selective, ["selected", "transcript"], [snapshot([asset], [Read]), read])
    assert AssetEvidence.observed(selective)["skill"] == [asset["sha256"]]
  end

  test "configuration must change actual tool disclosure at its declared request index" do
    asset = asset("configuration", %{"extension" => "search", "glob_after_requests" => 0})
    evidence = evidence(asset, [Read], [catalog(true), catalog(true)])

    evidence =
      put_in(evidence, ["original", "transcript"], [
        snapshot([], [Read]),
        catalog(false),
        catalog(true)
      ])

    assert AssetEvidence.observed(evidence)["configuration"] == [asset["sha256"]]

    unchanged =
      put_in(evidence, ["selected", "transcript"], [
        snapshot([asset], [Read]),
        catalog(false),
        catalog(true)
      ])

    assert AssetEvidence.observed(unchanged)["configuration"] == []

    assert AssetEvidence.observed(%{}) == %{
             "skill" => [],
             "configuration" => [],
             "tool_description" => []
           }
  end

  defp asset(kind, payload),
    do: %{
      "id" => "asset-#{kind}",
      "sha256" => Contract.sha256(kind),
      "content" => %{"kind" => kind, "payload" => payload}
    }

  defp evidence(asset, tools, entries),
    do: %{
      "original" => %{"transcript" => [snapshot([], [Read])]},
      "selected" => %{"transcript" => [snapshot([asset], tools) | entries]},
      "asset_search" => %{"candidates" => [%{"asset" => asset}]},
      "asset_application" => %{"asset_sha256" => [asset["sha256"]], "restored" => true}
    }

  defp snapshot(assets, tools) do
    resolved =
      Enum.map(assets, &Map.put(Map.take(&1, ~w(id sha256)), "kind", &1["content"]["kind"]))

    payload =
      Request.new("test:model", tools: tools)
      |> Snapshot.build(resolved_assets: resolved)
      |> Snapshot.to_map()

    %{"type" => "harness_snapshot", "payload" => payload}
  end

  defp result(name, arguments),
    do: %{
      "type" => "tool_result",
      "payload" => %{
        "name" => name,
        "arguments" => arguments,
        "error" => false
      }
    }

  defp catalog(visible),
    do: %{
      "type" => "request",
      "payload" => %{
        "catalog" => %{
          "per_tool" => if(visible, do: [%{"name" => "glob"}], else: [])
        }
      }
    }
end
