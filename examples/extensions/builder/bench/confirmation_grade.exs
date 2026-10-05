# Grades one confirmation attempt. Arguments: the workspace copy, the case id,
# the sealed inputs root and the Lemieux checkout whose compiled ebin directories
# make the native-tool compile check possible offline. Any failed match raises,
# so the benchmark records a rejected attempt together with the reason.
[cwd, id, inputs, repository] = System.argv()
original = Path.join(inputs, id)
read_json = fn path -> path |> File.read!() |> JSON.decode!() end

unchanged = fn file ->
  File.read!(Path.join(cwd, file)) == File.read!(Path.join(original, file))
end

unchanged_tree = fn relative ->
  for file <- Path.wildcard(Path.join([original, relative, "**"]), match_dot: true),
      File.regular?(file) do
    true = unchanged.(Path.relative_to(file, original))
  end
end

notes! = fn path ->
  notes = File.read!(path)
  true = String.length(notes) > 40
  notes
end

outcome! = fn ->
  %{"benchmarked" => false, "qualification" => "unassessed"} =
    read_json.(Path.join(cwd, "outcome.json"))
end

# The same path rules `Lemieux.Learning.Extension.Export.export/2` enforces: root project files
# plus lib/, priv/, test/ and bench/. A manifest naming anything else exports
# nothing, so "consistent" means every entry is exportable and present.
root_files = ~w(mix.exs mix.lock .formatter.exs README.md BUILDING.md LICENSE LICENSE.md)

allowed_path? = fn path ->
  path in root_files or
    match?(
      [directory, _ | _] when directory in ["lib", "priv", "test", "bench"],
      Path.split(path)
    )
end

valid_manifest! = fn ext, module ->
  manifest = read_json.(Path.join(ext, "lemieux-extension.json"))
  1 = manifest["schema_version"]
  ^module = manifest["module"]
  files = manifest["files"]
  true = is_list(files) and files == Enum.uniq(files) and "mix.exs" in files
  false = "lemieux-extension.json" in files
  false = "lemieux-extension-export.json" in files

  true =
    Enum.all?(files, fn file ->
      is_binary(file) and allowed_path?.(file) and File.regular?(Path.join(ext, file))
    end)

  manifest
end

exportable_files = fn ext ->
  for file <- Path.wildcard(Path.join(ext, "**"), match_dot: true),
      File.regular?(file),
      relative = Path.relative_to(file, ext),
      allowed_path?.(relative),
      do: relative
end

# Compiles the extension's lib/ in this fresh VM against the checkout's own
# compiled dependencies, without Mix, network or the extension's deps.
compile_extension! = fn ext, module_name ->
  ebins = Path.wildcard(Path.join(repository, "_build/dev/lib/*/ebin"))
  true = ebins != []
  Enum.each(ebins, &(true = Code.prepend_path(&1)))
  {:module, Lemieux.Tool} = Code.ensure_loaded(Lemieux.Tool)
  sources = ext |> Path.join("lib/**/*.ex") |> Path.wildcard() |> Enum.sort()
  Enum.each(sources, &Code.compile_file/1)
  module = Module.concat([module_name])
  true = function_exported?(module, :tool_registry, 0)
  registry = module.tool_registry()
  :ok = Lemieux.Tool.validate_all(registry)
  registry
end

invoke! = fn registry, name, args, expected ->
  {:ok, tool} = Lemieux.Tool.fetch(registry, name)

  context = %{
    cwd: cwd,
    environment: Lemieux.Environment.local(),
    session_id: "grader",
    call_id: "grader",
    session: self(),
    supervisor: nil
  }

  {:ok, text} = Lemieux.Tool.collect(Lemieux.Tool.invoke(tool, args, context))
  ^expected = String.trim(text)
end

native_tool! = fn name, expected ->
  for file <- ~w(README.md mix.exs .formatter.exs), do: true = unchanged.(file)
  unchanged_tree.("bench")
  registry = compile_extension!.(cwd, "LineAudit")
  true = name in Enum.map(registry, &Lemieux.Tool.name/1)
  profile = read_json.(Path.join(cwd, "priv/profile.json"))
  expected_profile = read_json.(Path.join(original, "priv/profile.json"))
  true = name in profile["tools"]
  true = Enum.sort(profile["tools"] -- [name]) == Enum.sort(expected_profile["tools"])
  true = Map.delete(profile, "tools") == Map.delete(expected_profile, "tools")
  :ok = Lemieux.Extension.Profile.validate(profile, tool_registry: registry)
  manifest = valid_manifest!.(cwd, "LineAudit")
  original_manifest = read_json.(Path.join(original, "lemieux-extension.json"))
  true = Enum.all?(original_manifest["files"], &(&1 in manifest["files"]))

  lib_files =
    cwd |> Path.join("lib/**/*.ex") |> Path.wildcard() |> Enum.map(&Path.relative_to(&1, cwd))

  true = Enum.all?(lib_files, &(&1 in manifest["files"]))
  notes = notes!.(Path.join(cwd, "BUILDING.md"))
  true = String.contains?(notes, name)
  File.write!(Path.join(cwd, "grader_sample.txt"), "alpha beta\ngamma\n")
  invoke!.(registry, name, %{"path" => "grader_sample.txt"}, expected)
end

case id do
  audit when audit in ["audit_admission_clean", "audit_admission_seeded"] ->
    unchanged_tree.("lib")
    notes!.(Path.join(cwd, "BUILDING.md"))
    findings = read_json.(Path.join(cwd, "review.json"))["findings"]

    if id == "audit_admission_clean" do
      [] = findings
    else
      [finding] = findings
      "lib/lemieux/subagent/admission.ex" = finding["file"]
      true = String.contains?(finding["quote"], "spent + incoming <= ceiling")
      true = String.length(finding["description"]) > 20
    end

  "tool_count_lines" ->
    native_tool!.("count_lines", "2")

  "tool_word_count" ->
    true = unchanged.("lib/line_audit/tools/word_count.ex")
    true = unchanged.("lemieux-extension.json")
    native_tool!.("word_count", "3")

  "dep_add" ->
    ext = Path.join(cwd, "line_stats")
    mix = File.read!(Path.join(ext, "mix.exs"))
    Code.string_to_quoted!(mix)
    true = Regex.match?(~r/\{:text_stats,\s*path:\s*"\.\.\/vendor\/text_stats"\}/, mix)

    # The scaffold's own Lemieux dependency, kept: a path from
    # LEMIEUX_EXTENSION_BASE when it is set, else the Hex requirement.
    true = String.contains?(mix, ~s|System.get_env("LEMIEUX_EXTENSION_BASE")|)
    true = String.contains?(mix, ~s|path -> {:lemieux, path: path}|)

    true = String.contains?(mix, "app: :line_stats")
    Enum.each(~w(vendor line_stats/lib line_stats/priv line_stats/bench), unchanged_tree)
    for file <- ~w(line_stats/README.md line_stats/.formatter.exs), do: true = unchanged.(file)
    manifest = valid_manifest!.(ext, "LineStats")
    lock? = File.regular?(Path.join(ext, "mix.lock"))

    true =
      if lock?, do: "mix.lock" in manifest["files"], else: "mix.lock" not in manifest["files"]

    notes = notes!.(Path.join(ext, "BUILDING.md"))
    true = String.contains?(notes, "text_stats")
    outcome!.()

  "dep_manifest" ->
    ext = Path.join(cwd, "line_stats")

    Enum.each(
      ~w(vendor line_stats/lib line_stats/priv line_stats/bench line_stats/test),
      unchanged_tree
    )

    for file <-
          ~w(line_stats/mix.exs line_stats/mix.lock line_stats/README.md line_stats/.formatter.exs),
        do: true = unchanged.(file)

    manifest = valid_manifest!.(ext, "LineStats")
    expected = Enum.sort(exportable_files.(Path.join(original, "line_stats")))
    ^expected = Enum.sort(manifest["files"])
    notes = notes!.(Path.join(ext, "BUILDING.md"))
    true = String.contains?(String.downcase(notes), "manifest")
    outcome!.()

  "models_reconcile" ->
    expected = [
      %{"model" => "zai_coding_plan:glm-4.7", "efforts" => ["default"]},
      %{"model" => "zai_coding_plan:glm-5.3", "efforts" => ["default"]}
    ]

    ^expected = read_json.(Path.join(cwd, "bench/models.json"))
    Enum.each(~w(lib priv bench/cases), unchanged_tree)

    for file <-
          ~w(README.md mix.exs .formatter.exs lemieux-extension.json bench/suite.json bench/grade.sh bench/workbench.exs bench/freeze.exs),
        do: true = unchanged.(file)

    notes = notes!.(Path.join(cwd, "BUILDING.md"))
    true = String.contains?(notes, "Decision: compare only the developer's explicit shortlist")
    outcome!.()

  "scaffold_quota" ->
    ext = Path.join(cwd, "log_triage")
    profile = read_json.(Path.join(ext, "priv/profile.json"))
    "live" = profile["execution"]
    "zai_coding_plan:glm-5.3" = profile["model"]
    ["bash", "read"] = Enum.sort(profile["tools"])

    true =
      profile["options"] == %{
        "system" => "Triage one log file and name the first failing step.",
        "max_turns" => 7,
        "max_tokens" => 1536,
        "temperature" => 0.1,
        "reasoning_effort" => "low",
        "usage_mode" => "quota",
        "max_requests" => 5,
        "max_cost_usd" => nil
      }

    valid_manifest!.(ext, "LogTriage")
    true = File.regular?(Path.join(ext, "lib/log_triage.ex"))

    [%{"model" => "zai_coding_plan:glm-5.3", "efforts" => ["low"]}] =
      read_json.(Path.join(ext, "bench/models.json"))

    notes = notes!.(Path.join(ext, "BUILDING.md"))
    true = String.contains?(String.downcase(notes), "confirmation")
    false = File.exists?(Path.join(cwd, "tmp"))
    false = File.exists?(Path.join(ext, "tmp"))
end

IO.puts("Accepted artifacts and preserved inputs")
