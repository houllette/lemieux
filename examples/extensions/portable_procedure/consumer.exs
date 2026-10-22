# Executed by the review command inside a fresh Mix consumer with the exported
# native project as a path dependency. These are host inputs, not package grants.
[expected_asset, expected_package, package] = System.argv()
:ok = Lemieux.Learning.Extension.Export.verify(package)
inventory = JSON.decode!(File.read!(Path.join(package, "lemieux-extension-export.json")))
true = inventory["sha256"] == expected_package
true = Application.spec(:lemieux, :mod) in [nil, []]
true = Application.spec(:portable_procedure, :mod) in [nil, []]

profile = %{
  "execution" => "scripted",
  "model" => "test:portable-procedure",
  "tools" => ["read", "write"],
  "options" => %{"enabled" => true, "asset_sha256" => expected_asset}
}

cwd = Path.join(File.cwd!(), "workspace")
File.mkdir!(cwd)
File.write!(Path.join(cwd, "records.json"), JSON.encode!([" alpha ", "", " beta "]))
{:ok, options, ^profile} = PortableProcedure.configure(profile)
options = Keyword.put(options, :sessions_dir, Path.join(File.cwd!(), "sessions"))

{:ok, result} =
  Lemieux.Agent.run(
    PortableProcedure,
    %{prompt: "Normalize records", cwd: cwd, timeout_ms: 30_000},
    options
  )

records = JSON.decode!(File.read!(Path.join(cwd, "normalized.json")))

report =
  Map.take(result, ~w(resolved_assets rolled_back tool_metrics))
  |> Map.put("records", records)
  |> Map.put("library_application_callback", false)
  |> Map.put("runtime", %{
    "lemieux" => Lemieux.version(),
    "elixir" => System.version(),
    "otp" => System.otp_release(),
    "req_llm" => to_string(Application.spec(:req_llm, :vsn))
  })

File.write!("installed.json", JSON.encode!(report))
