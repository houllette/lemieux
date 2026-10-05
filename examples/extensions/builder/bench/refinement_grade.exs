[cwd, id, inputs] = System.argv()
original = Path.join(inputs, id)
read_json = fn path -> path |> File.read!() |> JSON.decode!() end

unchanged = fn file ->
  File.read!(Path.join(cwd, file)) == File.read!(Path.join(original, file))
end

notes = File.read!(Path.join(cwd, "BUILDING.md"))
true = String.length(notes) > 40

case id do
  audit when audit in ["audit_clean", "audit_bound"] ->
    for file <- Path.wildcard(Path.join(original, "lib/**/*.ex")) do
      true = unchanged.(Path.relative_to(file, original))
    end

    findings = read_json.(Path.join(cwd, "review.json"))["findings"]

    if id == "audit_clean" do
      [] = findings
    else
      [finding] = findings
      "lib/lemieux/learning/extension/workbench.ex" = finding["file"]
      true = String.contains?(finding["quote"], "max(existing, maximum)")
      true = String.length(finding["description"]) > 20
    end

  repair when repair in ["repair_profile", "continue_work"] ->
    true = unchanged.("lib/agent.ex")
    true = unchanged.("README.md")
    true = String.contains?(notes, "Preserve line citations in every summary.")

    %{"benchmarked" => false, "qualification" => "unassessed"} =
      read_json.(Path.join(cwd, "outcome.json"))

    expected = read_json.(Path.join(original, "priv/profile.json"))

    expected =
      if id == "repair_profile",
        do: put_in(expected, ["options", "reasoning_effort"], "default"),
        else: expected

    ^expected = read_json.(Path.join(cwd, "priv/profile.json"))

    if id == "continue_work" do
      expected = [
        %{"model" => "zai_coding_plan:glm-5.3", "efforts" => ["default", "low"]},
        %{"model" => "zai_coding_plan:glm-4.7", "efforts" => ["default"]}
      ]

      ^expected = read_json.(Path.join(cwd, "bench/models.json"))
    end
end

IO.puts("Accepted artifacts and preserved inputs")
