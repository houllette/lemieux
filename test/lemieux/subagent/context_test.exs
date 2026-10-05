defmodule Lemieux.Subagent.ContextTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Subagent.Acceptance
  alias Lemieux.Subagent.Context
  alias Lemieux.Subagent.Result
  alias Lemieux.Subagent.Task

  test "only selected evidence enters a fresh brief and its digest changes task identity" do
    secret = Entry.new(:user, %{"text" => "not selected"})
    decision = Entry.new(:user, %{"text" => "retain compatibility"})
    assert {:ok, packet} = Context.select("parent", [secret, decision], [decision.id])
    brief = Task.new(objective: "inspect", snapshot: %{"revision" => "one"}, context: packet)
    assert Task.prompt(brief) =~ "retain compatibility"
    refute Task.prompt(brief) =~ "not selected"
    refute Task.digest(brief) == Task.digest(%{brief | context: nil})
    assert {:error, _} = Context.select("parent", [decision], ["missing"])
    assert {:error, _} = Context.select("parent", [decision], [decision.id, decision.id])
    tampered = put_in(packet, ["entries", Access.at(0), "payload", "text"], "changed")
    assert {:error, _} = Context.validate(tampered)
    large = Entry.new(:user, %{"text" => String.duplicate("x", 33_000)})
    assert {:error, _} = Context.select("parent", [large], [large.id])
  end

  test "execution, format and acceptance remain separate and assessment survives serialization" do
    result = %Result{
      child_id: "c",
      definition_id: "d",
      definition_digest: "digest",
      status: :ok,
      format: :prose,
      answer: "useful answer",
      transcript_id: "c"
    }

    task =
      Task.new(
        objective: "inspect",
        snapshot: %{"revision" => "one"},
        acceptance_criteria: ["source"]
      )

    unverified = Acceptance.assess(result, task, %{})
    assert unverified.acceptance["status"] == "unverified"
    passed = Acceptance.assess(result, task, %{"source" => fn _ -> {:pass, ["entry:123"]} end})
    assert passed.acceptance["status"] == "passed"
    assert passed.status == :ok
    assert passed.format == :prose
    assert {:ok, ^passed} = passed |> Result.to_map() |> Result.from_map()
    failed = Acceptance.assess(result, task, %{"source" => fn _ -> {:fail, "contradicted"} end})
    assert failed.acceptance["status"] == "failed"
    assert failed.answer == result.answer
    error = Acceptance.assess(result, task, %{"source" => fn _ -> raise "bad checker" end})
    assert error.acceptance["status"] == "unverified"

    stopped =
      Acceptance.assess(%{result | status: :cancelled}, task, %{
        "source" => fn _ -> {:pass, ["entry:123"]} end
      })

    assert stopped.acceptance["status"] == "unverified"
  end
end
