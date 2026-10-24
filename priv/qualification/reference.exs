defmodule LemieuxQualificationReference do
  @moduledoc false
  alias Lemieux.CLI.Learning.QualificationHost
  alias Lemieux.Contract
  alias Lemieux.Providers.Scripted
  alias Lemieux.Tool

  @usage %{"input_tokens" => 2, "output_tokens" => 2}
  @helper "from pathlib import Path\nprint('workspace files:', len(list(Path('.').rglob('*.py'))))\n"

  def provider(:asset_proposer, _fixture, _model, _effort, _requests) do
    Scripted.new([
      fn request ->
        entry = request.entries |> Enum.filter(&(&1.type == :user)) |> List.last()
        input = JSON.decode!(entry.payload["text"])
        kinds = input["allowed_asset_kinds"] || ["skill", "configuration"]
        selected = assets() |> Enum.filter(&(&1["kind"] in kinds))
        selected = Enum.map(selected, &helper_policy(&1, input["helper_extensions"] || []))
        Scripted.complete(JSON.encode!(%{"assets" => selected}), usage: @usage)
      end
    ])
  end

  def provider(:asset_critic, _fixture, _model, _effort, _requests) do
    Scripted.new([
      fn request ->
        entry = request.entries |> Enum.filter(&(&1.type == :user)) |> List.last()
        input = JSON.decode!(entry.payload["text"])

        Scripted.complete(
          JSON.encode!(%{
            "asset_sha256" => input["asset_sha256"],
            "decision" => "approve",
            "reason" => "Offline reference workflow components; no efficacy inference."
          }),
          usage: @usage
        )
      end
    ])
  end

  def provider(:reflection, _fixture, _model, _effort, _requests) do
    hypothesis = %{
      "kind" => "procedure",
      "outcome" => "insufficient_evidence",
      "mechanism" =>
        "Read development entry points, repair active source, regenerate the executed copy and verify both paths.",
      "applicability" => ["coding verification failure recovery repository workflow"]
    }

    Scripted.new([
      fn request ->
        entry = request.entries |> Enum.filter(&(&1.type == :user)) |> List.last()
        marker = "\nCitation index (copy exact pointer strings; seq is NOT an array index):\n"
        [_source, index] = String.split(entry.payload["text"], marker, parts: 2)
        [pointer | _] = JSON.decode!(index)
        hypothesis = Map.put(hypothesis, "source_pointers", [pointer["pointer"]])
        Scripted.complete(JSON.encode!(%{"lessons" => [hypothesis]}), usage: @usage)
      end
    ])
  end

  def provider(:proposer, fixture, model, effort, requests) do
    profile =
      QualificationHost.baseline(model, effort, requests)
      |> update_in(
        ["options", "system"],
        &(&1 <> " Trace active source and regenerate runtime artifacts before verification.")
      )

    manifest = %{
      "rationale" => "Observed source and runtime artifacts require a coherent workflow.",
      "hypothesis" => "Explicit artifact workflow preserves successful execution.",
      "targeted_cluster" => nil,
      "mechanism" => "source_runtime_coherence",
      "changed_paths" => ["options.system"],
      "predicted_fixes" => [fixture.id],
      "predicted_at_risk" => []
    }

    Scripted.new([
      call("parent", "read", %{"path" => "parent/profile.json"}),
      call("lessons", "read", %{"path" => "evidence/lessons/index.json"}),
      call("profile", "write", %{
        "path" => "proposal/profile.json",
        "content" => Contract.encode!(profile)
      }),
      call("manifest", "write", %{
        "path" => "proposal/manifest.json",
        "content" => Contract.encode!(manifest)
      }),
      Scripted.complete("offline proposal", usage: @usage)
    ])
  end

  def provider(_role, %{offline_oracle: _} = fixture, _model, _effort, _requests),
    do: Scripted.new(List.duplicate(fn request -> next(request, fixture) end, 16))

  def provider(_role, _fixture, _model, _effort, _requests),
    do: Scripted.new([Scripted.complete("offline mechanics", usage: @usage)])

  defp assets do
    [
      %{
        "kind" => "skill",
        "payload" => %{"name" => "source-workflow"},
        "requires_tools" => ~w(read write bash),
        "triggers" => ["repository workflow"],
        "files" => %{
          "SKILL.md" =>
            "---\nname: source-workflow\ndescription: Use for repository workflow and generated source.\n---\nRead [the helper](helpers/inventory.py), copy it into the workspace and run it to inspect the source tree. Repair source, regenerate the runtime, and verify. This is unconfirmed guidance.\n",
          "helpers/inventory.py" => @helper
        }
      },
      %{
        "kind" => "configuration",
        "payload" => %{"extension" => "search", "glob_after_requests" => 0},
        "requires_tools" => ["glob"],
        "triggers" => [],
        "files" => %{}
      }
    ]
  end

  defp next(request, fixture) do
    skill? = Enum.any?(request.tools, &(Tool.name(&1) == "skill"))
    steps = if skill?, do: helper_steps(request), else: []

    steps =
      steps ++
        [
          {"reproduce", "bash", %{"command" => "python checks.py"}},
          {"read-source", "read", %{"path" => "src/project/core.py"}},
          {"read-built", "read", %{"path" => ".build/project/core.py"}},
          {"source", "write",
           %{"path" => "src/project/core.py", "content" => fixture.offline_oracle}},
          {"built", "write",
           %{"path" => ".build/project/core.py", "content" => fixture.offline_oracle}},
          {"verify", "bash", %{"command" => "python checks.py"}}
        ]

    # A scripted intervention makes the workflow change observable without
    # pretending that this deterministic reference establishes hosted efficacy.
    steps =
      if String.contains?(request.system, "Trace active source and regenerate runtime"),
        do:
          Enum.sort_by(steps, fn {id, _, _} ->
            if id in ~w(read-source read-built), do: 0, else: 1
          end),
        else: steps

    case Enum.find(steps, fn {id, _, _} -> not called?(request, id) end) do
      nil -> Scripted.complete("offline reference repair", usage: @usage)
      {id, name, arguments} -> call(id, name, arguments)
    end
  end

  defp helper_policy(%{"kind" => "skill"} = asset, []) do
    files = %{
      "SKILL.md" =>
        "---\nname: source-workflow\ndescription: Use for repository workflow and generated source.\n---\nRead authoritative source and executed artifacts, repair source, regenerate the runtime and verify both paths. This is unconfirmed guidance.\n"
    }

    Map.put(asset, "files", files)
  end

  defp helper_policy(asset, _allowed), do: asset

  defp helper_steps(request) do
    body = tool_output(request, "skill-body")
    first = [{"skill-body", "skill", %{"name" => "source-workflow", "file" => "SKILL.md"}}]

    if is_nil(body) or String.contains?(body, "helpers/inventory.py") do
      code = tool_output(request, "skill-helper") || ""

      first ++
        [
          {"skill-helper", "skill",
           %{"name" => "source-workflow", "file" => "helpers/inventory.py"}},
          {"copy-helper", "write", %{"path" => "inventory.py", "content" => code}},
          {"run-helper", "bash", %{"command" => "python inventory.py"}}
        ]
    else
      first
    end
  end

  defp tool_output(request, id) do
    case Enum.find(request.entries, &(&1.type == :tool_result and &1.payload["call_id"] == id)) do
      nil -> nil
      entry -> entry.payload["output"] |> String.split("\n\n", parts: 2) |> List.last()
    end
  end

  defp called?(request, id),
    do: Enum.any?(request.entries, &(&1.type == :tool_result and &1.payload["call_id"] == id))

  defp call(id, name, arguments), do: Scripted.tool_call(id, name, arguments, usage: @usage)
end
