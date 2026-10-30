defmodule Lemieux.PortableAssetExampleTest do
  use ExUnit.Case, async: true
  alias Lemieux.Contract
  alias Lemieux.Learning.Extension.Export

  @moduletag :tmp_dir
  # Two separately bounded consumer commands plus export/verification. Keep
  # the case deadline outside their sum so a failed build retains its log.
  @tag timeout: :timer.minutes(7)
  test "the documented offline command exports, runs and rolls back an asset in fresh consumers",
       ctx do
    output = Path.join(ctx.tmp_dir, "review")
    options = [stderr_to_stdout: true, env: [{"MIX_ENV", Atom.to_string(Mix.env())}]]

    {log, status} =
      System.cmd(
        "mix",
        ["run", "--no-compile", "--no-start", "examples/portable_asset.exs", "--output", output],
        options
      )

    assert status == 0, log
    report = JSON.decode!(File.read!(Path.join(output, "review.json")))
    assert :ok = Contract.verify_digest(report, "sha256")
    assert report["driver_sha256"] == Contract.sha256(File.read!("examples/portable_asset.exs"))
    assert report["qualification"] == "unassessed"
    assert report["independent_confirmation"] == "not_run"
    assert report["hosted_requests"] == 0
    assert report["production_active"] == false
    assert report["before"]["records"] == ["alpha", "beta"]
    assert report["applied"]["records"] == ["alpha", "", "beta"]
    assert report["after_undo"]["records"] == report["before"]["records"]
    assert report["installed_consumer"]["records"] == report["applied"]["records"]
    assert report["installed_consumer"]["resolved_assets"] == report["applied"]["assets"]
    assert report["installed_consumer"]["rolled_back"]

    assert report["installed_consumer"]["runtime"]["req_llm"] ==
             to_string(Application.spec(:req_llm, :vsn))

    assert Enum.map(~w(before applied after_undo), &report[&1]["requests"]) == [2, 3, 2]
    assert [%{"sha256" => digest, "qualification" => "unconfirmed"}] = report["applied"]["assets"]
    assert digest == report["asset_sha256"]
    assert :ok = Export.verify(Path.join(output, "package"))
    assert File.read!(Path.join(output, "package/LICENSE")) == File.read!("LICENSE")
    refute File.exists?(Path.join(output, "package/lemieux-extension-qualification.json"))
    assert "microvm" in report["missing_code_gate_evidence"]

    {refused, status} =
      System.cmd(
        "mix",
        ["run", "--no-compile", "--no-start", "examples/portable_asset.exs", "--output", output],
        options
      )

    assert status != 0
    assert refused =~ "already exists"
    assert JSON.decode!(File.read!(Path.join(output, "review.json"))) == report
  end
end
