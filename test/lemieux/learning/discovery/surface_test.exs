defmodule Lemieux.Learning.Discovery.SurfaceTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Learning.Discovery.Plan
  alias Lemieux.Learning.Discovery.Surface

  test "the validator identity is stable and digest-bearing" do
    assert %{"id" => "lemieux.profile-surface/v1", "sha256" => sha} = Surface.validator()
    assert sha == Contract.sha256("lemieux.profile-surface/v1")
  end

  test "changed paths are dotted leaves, with lists compared whole" do
    parent = %{
      "options" => %{"system" => "a", "tool_descriptions" => %{"read" => "r"}},
      "tools" => ["read"]
    }

    candidate = %{
      "options" => %{"system" => "b", "tool_descriptions" => %{"read" => "r", "bash" => "x"}},
      "tools" => ["read", "bash"]
    }

    assert Surface.changed_paths(parent, candidate) == [
             "options.system",
             "options.tool_descriptions.bash",
             "tools"
           ]

    assert Surface.changed_paths(parent, parent) == []
  end

  test "edits outside the surface, no-ops, grader references and oversize content are refused" do
    plan =
      plan([%{"path" => "options.system"}, %{"path" => "options.tool_descriptions"}], [
        %{"id" => "safe", "kind" => "mechanical"},
        %{
          "id" => "graders",
          "kind" => "forbidden_references",
          "patterns" => ["check.sh", "grader"]
        },
        %{"id" => "size", "kind" => "max_content_bytes", "value" => 200}
      ])

    parent = %{"model" => "m", "options" => %{"system" => "a", "tool_descriptions" => %{}}}

    ok = %{
      "model" => "m",
      "options" => %{"system" => "b", "tool_descriptions" => %{"read" => "Read a file"}}
    }

    assert {:ok, %{"changed_paths" => paths, "size_bytes" => _}} =
             Surface.validate(plan, parent, ok, JSON.encode!(ok), "clonal")

    assert paths == ["options.system", "options.tool_descriptions.read"]

    outside = %{"model" => "other", "options" => %{"system" => "b", "tool_descriptions" => %{}}}

    assert {:error, {:outside_surface, ["model"]}} =
             Surface.validate(plan, parent, outside, JSON.encode!(outside), "clonal")

    assert {:error, :no_change} =
             Surface.validate(plan, parent, parent, JSON.encode!(parent), "clonal")

    assert {:ok, %{"changed_paths" => []}} =
             Surface.validate(plan, parent, parent, JSON.encode!(parent), "seed")

    grader = %{
      "model" => "m",
      "options" => %{"system" => "always run CHECK.sh first", "tool_descriptions" => %{}}
    }

    assert {:error, {:forbidden_reference, "check.sh"}} =
             Surface.validate(plan, parent, grader, JSON.encode!(grader), "clonal")

    huge = %{
      "model" => "m",
      "options" => %{"system" => String.duplicate("x", 300), "tool_descriptions" => %{}}
    }

    assert {:error, {:content_too_large, size, 200}} =
             Surface.validate(plan, parent, huge, JSON.encode!(huge), "clonal")

    assert size > 200
  end

  test "interface validation records the validator digest for both outcomes" do
    assert %{
             "status" => "passed",
             "validator_sha256" => sha,
             "detail" => %{"changed_paths" => ["x"]}
           } =
             Surface.interface_validation({:ok, %{"changed_paths" => ["x"]}})

    assert sha == Surface.validator()["sha256"]

    assert %{"status" => "failed", "detail" => %{"error" => error}} =
             Surface.interface_validation({:error, {:outside_surface, ["model"]}})

    assert error == ["outside_surface", ["model"]]
  end

  defp plan(surface, constraints) do
    {:ok, plan} =
      Plan.new(%{
        "id" => "plan-surface",
        "scope" => %{"id" => "tenant-a/project-a"},
        "target_interface" => %{"id" => "profile/v1"},
        "mutation_surface" => surface,
        "seeds" => [%{"id" => "seed-1", "content_sha256" => String.duplicate("a", 64)}],
        "proposer" => %{"id" => "proposer", "sha256" => String.duplicate("b", 64)},
        "base_model" => %{"id" => "test:model", "sha256" => String.duplicate("c", 64)},
        "development_case_ids" => ["dev-1"],
        "validation_case_ids" => ["val-1"],
        "objectives" => [%{"name" => "task_success", "direction" => "maximize"}],
        "hard_constraints" => constraints,
        "interface_validator" => Surface.validator(),
        "budget" => %{
          "maximum_candidates" => 5,
          "maximum_tokens" => 1000,
          "maximum_cost_usd" => 1.0,
          "maximum_time_ms" => 1000
        }
      })

    plan
  end
end
