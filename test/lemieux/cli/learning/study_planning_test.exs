defmodule Lemieux.CLI.Learning.StudyPlanningTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.StudyPlanning
  alias Lemieux.Contract
  @moduletag :tmp_dir

  @tag timeout: :timer.minutes(3)
  test "the real runner plans a hosted scope with no Docker, credentials, ledger or episodes", %{
    tmp_dir: dir
  } do
    output = Path.join(dir, "plan")
    allowance = Path.join(dir, "allowance")
    bin = Path.join(dir, "bin")
    File.mkdir!(bin)
    File.write!(Path.join(bin, "docker"), "#!/bin/sh\nexit 99\n")
    File.chmod!(Path.join(bin, "docker"), 0o755)

    {stdout, status} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-compile",
          "--no-start",
          "scripts/qualify_learning_study.exs",
          "--plan-only",
          "--research",
          "--stage",
          "mechanism",
          "--assets",
          "--asset-only",
          "--asset-kinds",
          "tool_description",
          "--no-asset-helpers",
          "--model",
          "openai_codex:gpt-6-luna",
          "--effort",
          "low",
          "--editor-model",
          "openai_codex:gpt-6-sol",
          "--editor-effort",
          "high",
          "--allowance-dir",
          allowance,
          "--max-total-requests",
          "800",
          "--max-total-tokens",
          "8000000",
          "--max-total-time-ms",
          "7200000",
          "--output",
          output
        ],
        stderr_to_stdout: true,
        env: [
          # Mix aliases select :test only in their own VM. A child defaults to
          # :dev without this, where a clean release checkout has no compiled app.
          {"MIX_ENV", Atom.to_string(Mix.env())},
          {"PATH", bin <> ":" <> System.get_env("PATH")},
          {"LMX_CONFIG", "none"},
          {"ERL_FLAGS", "+S 2:2"}
        ]
      )

    assert status == 0, stdout
    review = JSON.decode!(File.read!(Path.join(output, "planning.json")))
    registration = JSON.decode!(File.read!(Path.join(output, "registration.json")))
    assert review["dispatches"] == 0
    assert review["target_episodes"] == 12
    assert review["maximum_registered_requests"] == 13 * 77

    assert get_in(registration, ["template", "runtime", "research_protocol", "id"]) ==
             "whole_record_research/v8"

    assert get_in(registration, ["template", "runtime", "research_protocol", "asset_search", "id"]) ==
             "reviewed_assets/v5"

    assert get_in(registration, [
             "template",
             "runtime",
             "research_protocol",
             "asset_search",
             "kinds"
           ]) == ["tool_description"]

    refute File.exists?(allowance)
    refute File.exists?(Path.join(output, ".auth"))
    refute File.exists?(Path.join(output, "plan.json"))
    refute File.exists?(Path.join(output, "report.json"))
    assert Path.wildcard(Path.join(output, "**/evidence.json")) == []
    assert review["registration_sha256"] == Contract.digest(registration)
  end

  test "review includes acquisition and every arm/repetition without treating a ceiling as sample completion" do
    registration = %{
      "template" => %{
        "sha256" => Contract.sha256("plan"),
        "tasks" => [%{"cluster" => "a"}, %{"cluster" => "a"}, %{"cluster" => "b"}],
        "repetitions" => 2,
        "arms" => ~w(disabled retrieval retry frozen updating no_experience),
        "allowance" => %{"requests" => 100},
        "model" => "test:model",
        "effort" => "default",
        "claim" => "development_qualification"
      },
      "seed_tasks" => [%{"id" => "seed-a"}, %{"id" => "seed-b"}],
      "seed_allowance" => %{"requests" => 12}
    }

    review =
      StudyPlanning.review(registration, max_requests: 800, max_tokens: 8000, max_time_ms: 1000)

    assert review["maximum_registered_requests"] == 3624
    assert review["target_episodes"] == 36
    assert review["streams"] == 2
    assert review["seed_episodes"] == 2
    assert review["ceiling_can_stop_sample"]
    assert review["hosted_authorization"] == "required_separately"
    assert review["dispatches"] == 0
    refute review["credentials_prepared"]
    assert review["registration_sha256"] == Contract.digest(registration)
    assert :ok = Contract.verify_digest(review, "sha256")

    complete = StudyPlanning.review(registration, max_requests: 3624)
    refute complete["ceiling_can_stop_sample"]
    assert complete["hosted_authorization"] == "required_separately"
  end
end
