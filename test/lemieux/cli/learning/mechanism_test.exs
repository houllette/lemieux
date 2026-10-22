defmodule Lemieux.CLI.Learning.MechanismTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Mechanism
  alias Lemieux.Contract

  test "larger runs require the same frozen mechanism, model, editor and inference route" do
    runtime = %{
      "revision" => String.duplicate("a", 40),
      "inference_route" => "codex_subscription",
      "research_protocol" => %{
        "stage" => "mechanism",
        "editor_model" => "editor",
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
          put_in(current, ["research_protocol", "editor_model"], "other")
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

  defp seal(map),
    do: map |> Map.delete("sha256") |> then(&Map.put(&1, "sha256", Contract.digest(&1)))
end
