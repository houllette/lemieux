# Fresh consumer inputs are supplied by the receiving host, never the package.
[expected_asset, expected_package, package] = System.argv()
:ok = Lemieux.Learning.Extension.Export.verify(package)
inventory = JSON.decode!(File.read!(Path.join(package, "lemieux-extension-export.json")))
true = inventory["sha256"] == expected_package
true = Application.spec(:lemieux, :mod) in [nil, []]
true = Application.spec(:learned_skill_witness, :mod) in [nil, []]

profile = %{
  "execution" => "scripted",
  "model" => "test:learned-skill-witness",
  "tools" => ~w(read write edit bash glob),
  "options" => %{"enabled" => true, "asset_sha256" => expected_asset}
}

cwd = Path.join(File.cwd!(), "workspace")
File.mkdir!(cwd)
{:ok, options, ^profile} = LearnedSkillWitness.configure(profile)
options = Keyword.put(options, :sessions_dir, Path.join(File.cwd!(), "sessions"))

{:ok, result} =
  Lemieux.Agent.run(
    LearnedSkillWitness,
    %{prompt: "Witness the packaged procedure bytes", cwd: cwd, timeout_ms: 30_000},
    options
  )

report =
  Map.take(result, ~w(resolved_assets rolled_back tool_metrics))
  |> Map.put("witness", JSON.decode!(File.read!(Path.join(cwd, "witness.json"))))
  |> Map.put("library_application_callback", false)
  |> Map.put("runtime", %{
    "lemieux" => Lemieux.version(),
    "elixir" => System.version(),
    "otp" => System.otp_release(),
    "req_llm" => to_string(Application.spec(:req_llm, :vsn))
  })

File.write!("installed.json", JSON.encode!(report))
