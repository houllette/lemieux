defmodule Lemieux.CLI.CompatibilityTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.CLI.ProviderAccess
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  test "explain identifies effective inputs and exclusions without executing or leaking them", %{
    tmp_dir: dir
  } do
    File.mkdir_p!(Path.join(dir, ".git"))
    File.write!(Path.join(dir, "AGENTS.md"), "superseded")
    override = Path.join(dir, "AGENTS.override.md")
    File.write!(override, "loaded-instruction-canary")
    rules = Path.join([dir, ".claude", "rules"])
    File.mkdir_p!(rules)
    File.write!(Path.join(rules, "scoped.md"), "---\npaths: src/**\n---\nrule-content-canary")
    File.write!(Path.join(dir, "opencode.json"), "vendor-config-canary")
    skill = Path.join([dir, ".agents", "skills", "review", "SKILL.md"])
    File.mkdir_p!(Path.dirname(skill))

    File.write!(
      skill,
      "---\nname: review\ndescription: Project review.\n---\nprivate-skill-body-canary"
    )

    provider = Scripted.new([])

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run(
                   ["explain", "--config", "none", "--no-delegate", "--max-total-requests", "7"],
                   cwd: dir,
                   provider: provider
                 )
      end)

    report = JSON.decode!(output)["diagnostics"]
    compatibility = report["compatibility"]

    assert Enum.any?(
             compatibility["skills"],
             &(&1["name"] == "review" and &1["builtin_collision"] == "review")
           )

    refute output =~ "private-skill-body-canary"
    assert compatibility["status"] == "discovered"

    assert [%{"path" => ^override}] =
             Enum.filter(compatibility["inputs"], &(&1["kind"] == "instructions"))

    assert [%{"activation" => "native_file_tool", "paths" => ["./src/**"]}] =
             compatibility["rules"]

    assert [%{"path" => "opencode.json", "status" => "not_imported"}] =
             compatibility["unsupported_files"]

    assert report["provider_access"]["economics"]["limits"]["job_limits"]["max_requests"] == 7
    assert report["provider_access"]["access"]["subscription_entitlement"] == "not_assumed"
    refute output =~ "loaded-instruction-canary"
    refute output =~ "rule-content-canary"
    refute output =~ "vendor-config-canary"
    assert Scripted.requests(provider) == []
  end

  test "known catalog rates are forecasts while unknown providers stay unknown" do
    known =
      ProviderAccess.report(
        "openai:gpt-4o-mini",
        %{"status" => "present_not_verified"},
        "provider_compatible_gateway",
        %{}
      )

    assert known["access"]["verified"] == false
    assert known["catalog"]["status"] == "installed_catalog_only"
    assert is_number(known["catalog"]["prices"]["input"])
    assert known["catalog"]["endpoint_qualified"] == false
    assert known["economics"]["actual_tariff"] == "unknown_until_metered"

    unknown =
      ProviderAccess.report("custom:unlisted", %{"status" => "host_managed"}, "custom", %{})

    assert unknown["catalog"]["status"] == "unknown"
    assert unknown["catalog"]["prices"] == nil
    assert unknown["catalog"]["context_window"] == nil
  end
end
