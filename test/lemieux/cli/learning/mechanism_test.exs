defmodule Lemieux.CLI.Learning.MechanismTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.AssetPolicy
  alias Lemieux.CLI.Learning.AssetSearch
  alias Lemieux.CLI.Learning.Mechanism
  alias Lemieux.CLI.Learning.Transport
  alias Lemieux.Contract

  test "v6 requires its declared scope and cannot reuse a v5 receipt" do
    runtime = %{
      "revision" => "revision",
      "inference_route" => "codex_subscription",
      "research_protocol" => %{
        "id" => "whole_record_research/v6",
        "profile_search" => false,
        "asset_search" => %{"kinds" => ["skill"], "helper_extensions" => []}
      }
    }

    required = Mechanism.requirements(runtime)

    receipt =
      seal(%{
        "kind" => "observed_learning_mechanism/v1",
        "status" => "passed",
        "required_checks" => required,
        "checks" => Map.new(required, fn {key, _} -> {key, true} end),
        "binding" => Map.merge(runtime, %{"model" => "model", "effort" => "high"})
      })

    assert :ok = Mechanism.gate(receipt, runtime, "model", "high")

    assert {:error, :matching_mechanism_required} =
             Mechanism.gate(
               seal(Map.put(receipt, "required_checks", %{})),
               runtime,
               "model",
               "high"
             )

    legacy =
      receipt
      |> put_in(["binding", "research_protocol", "id"], "whole_record_research/v5")
      |> seal()

    assert {:error, :matching_mechanism_required} =
             Mechanism.gate(legacy, runtime, "model", "high")
  end

  test "text-skill scope cannot qualify helper source, configuration or a profile search" do
    runtime = %{
      "revision" => String.duplicate("a", 40),
      "inference_route" => "codex_subscription",
      "research_protocol" => %{
        "id" => "whole_record_research/v5",
        "stage" => "mechanism",
        "profile_search" => false,
        "asset_search" => %{"kinds" => ["skill"], "helper_extensions" => []}
      }
    }

    required = Mechanism.requirements(runtime)
    assert required["procedure_exercised"]
    refute required["helper_executed"]
    refute required["setting_exercised"]
    refute required["profile_exercised"]

    receipt =
      seal(%{
        "kind" => "observed_learning_mechanism/v1",
        "status" => "passed",
        "required_checks" => required,
        "checks" => Map.new(required, fn {key, _} -> {key, true} end),
        "binding" => %{
          "revision" => runtime["revision"],
          "inference_route" => runtime["inference_route"],
          "research_protocol" => Map.delete(runtime["research_protocol"], "stage"),
          "model" => "model",
          "effort" => "high"
        }
      })

    assert :ok = Mechanism.gate(receipt, runtime, "model", "high")

    for changed <- [
          put_in(runtime, ["research_protocol", "asset_search", "helper_extensions"], [".py"]),
          put_in(runtime, ["research_protocol", "asset_search", "kinds"], ["configuration"]),
          put_in(runtime, ["research_protocol", "profile_search"], true)
        ] do
      assert {:error, :matching_mechanism_required} =
               Mechanism.gate(receipt, changed, "model", "high")
    end

    assert {:error, :matching_mechanism_required} =
             Mechanism.gate(seal(%{receipt | "required_checks" => %{}}), runtime, "model", "high")
  end

  test "larger runs require the same mechanism, model, editor, route and transport" do
    runtime = %{
      "revision" => String.duplicate("a", 40),
      "inference_route" => "codex_subscription",
      "research_protocol" => %{
        "stage" => "mechanism",
        "editor_model" => "editor",
        "http_transport" => Transport.policy(),
        "profile_search" => true
      }
    }

    binding = %{
      "revision" => runtime["revision"],
      "inference_route" => runtime["inference_route"],
      "research_protocol" => Map.delete(runtime["research_protocol"], "stage"),
      "model" => "model",
      "effort" => "low"
    }

    receipt =
      seal(%{
        "kind" => "observed_learning_mechanism/v1",
        "status" => "passed",
        "checks" => %{"chain" => true},
        "binding" => binding
      })

    current = put_in(runtime, ["research_protocol", "stage"], "development")
    assert :ok = Mechanism.gate(receipt, current, "model", "low")

    for changed <- [
          Map.put(current, "revision", String.duplicate("b", 40)),
          Map.put(current, "inference_route", "scripted"),
          put_in(current, ["research_protocol", "editor_model"], "other"),
          put_in(current, ["research_protocol", "http_transport", "id"], "shared_pool")
        ] do
      assert {:error, :matching_mechanism_required} =
               Mechanism.gate(receipt, changed, "model", "low")
    end

    assert {:error, _} = Mechanism.gate(receipt, current, "stronger", "low")

    assert {:error, _} =
             Mechanism.gate(
               seal(%{receipt | "status" => "not_demonstrated"}),
               current,
               "model",
               "low"
             )

    assert {:error, _} =
             Mechanism.gate(
               seal(put_in(receipt, ["checks", "chain"], false)),
               current,
               "model",
               "low"
             )
  end

  test "v7 binds the complete execution environment and cannot inherit a historical canary" do
    runtime = %{
      "revision" => String.duplicate("a", 40),
      "environment" => "networkless_nonroot_container",
      "image" => "sha256:python",
      "generation" => %{"task_requests" => 12, "max_tokens" => 8192},
      "inference_route" => "scripted",
      "research_protocol" => %{
        "id" => "whole_record_research/v7",
        "stage" => "mechanism",
        "profile_search" => true,
        "asset_search" => nil
      }
    }

    required = Mechanism.requirements(runtime)

    receipt =
      seal(%{
        "kind" => "observed_learning_mechanism/v2",
        "status" => "passed",
        "required_checks" => required,
        "checks" => Map.new(required, fn {key, _} -> {key, true} end),
        "binding" => Mechanism.execution_binding(runtime, "model", "low")
      })

    current = put_in(runtime, ["research_protocol", "stage"], "development")
    assert :ok = Mechanism.gate(receipt, current, "model", "low")

    for changed <- [
          Map.put(current, "image", "sha256:other"),
          Map.put(current, "environment", "network_enabled"),
          put_in(current, ["generation", "task_requests"], 24),
          put_in(current, ["generation", "max_tokens"], 16_384)
        ] do
      assert {:error, :matching_mechanism_required} =
               Mechanism.gate(receipt, changed, "model", "low")
    end

    assert {:error, :matching_mechanism_required} =
             Mechanism.gate(
               seal(Map.put(receipt, "kind", "observed_learning_mechanism/v1")),
               current,
               "model",
               "low"
             )

    assert {:error, :matching_mechanism_required} =
             Mechanism.gate(seal(Map.put(receipt, "checks", %{})), current, "model", "low")
  end

  test "v8 selective search needs a fresh v3 receipt with its exact policy and budget" do
    runtime = %{
      "revision" => String.duplicate("a", 40),
      "research_protocol" => %{
        "id" => "whole_record_research/v8",
        "stage" => "mechanism",
        "profile_search" => false,
        "asset_search" =>
          AssetSearch.protocol(kinds: ["skill"], selection_policy: AssetPolicy.policy())
      }
    }

    required = Mechanism.requirements(runtime)

    receipt =
      seal(%{
        "kind" => "observed_learning_mechanism/v3",
        "status" => "passed",
        "required_checks" => required,
        "checks" => Map.new(required, fn {key, _} -> {key, true} end),
        "binding" => Mechanism.execution_binding(runtime, "model", "low")
      })

    assert :ok = Mechanism.gate(receipt, runtime, "model", "low")

    changed =
      put_in(
        runtime,
        ["research_protocol", "asset_search", "selection_policy", "admission"],
        "all_observations"
      )

    assert {:error, :matching_mechanism_required} =
             Mechanism.gate(receipt, changed, "model", "low")

    assert {:error, :matching_mechanism_required} =
             Mechanism.gate(
               seal(Map.put(receipt, "kind", "observed_learning_mechanism/v2")),
               runtime,
               "model",
               "low"
             )
  end

  defp seal(map),
    do: map |> Map.delete("sha256") |> then(&Map.put(&1, "sha256", Contract.digest(&1)))
end
