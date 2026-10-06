defmodule Lmx.UpgradePlanTest do
  use ExUnit.Case, async: true
  alias Lmx.UpgradePlan

  @build String.duplicate("a", 64)
  defp plan do
    %{
      schema_version: 1,
      version: "0.2.0",
      from: "0.1.0",
      reviewed: true,
      targets:
        Map.new(
          Lmx.Release.targets(),
          &{&1, %{mode: :restart, reason: "Application state changed; a new VM is required."}}
        )
    }
  end

  defp hot(plan) do
    decision = %{
      mode: :hot,
      reason: "Only compatible module bodies changed.",
      from_build: @build,
      modules: %{lemieux: [Lemieux.TUI], lmx: []},
      review: %{
        state: "Existing state shapes and invariants are unchanged.",
        messages: "Existing message shapes are unchanged.",
        closures:
          "No retained local callbacks from changed modules; external captures resolve current code.",
        rollback: "Both versions read the same state and transcript schema."
      }
    }

    put_in(plan.targets["macos_silicon"], decision)
  end

  test "release gate refuses missing, unreviewed and mismatched predecessor decisions" do
    plan = plan()
    assert UpgradePlan.validate!(plan, "0.2.0", "0.1.0") == plan

    assert_raise Mix.Error, ~r/unreviewed/, fn ->
      UpgradePlan.validate!(%{plan | reviewed: false}, "0.2.0")
    end

    assert_raise Mix.Error, ~r/latest stable/, fn ->
      UpgradePlan.validate!(plan, "0.2.0", "0.0.9")
    end

    assert_raise Mix.Error, ~r/missing windows/, fn ->
      UpgradePlan.validate!(%{plan | targets: Map.delete(plan.targets, "windows")}, "0.2.0")
    end

    assert_raise Mix.Error, ~r/missing .*review/, fn ->
      UpgradePlan.read!("0.9.9", "/nonexistent")
    end
  end

  test "hot decisions require durable reviews and Windows uses restart" do
    plan = hot(plan())
    assert UpgradePlan.validate!(plan, "0.2.0") == plan

    assert_raise Mix.Error, ~r/state review/, fn ->
      UpgradePlan.validate!(put_in(plan.targets["macos_silicon"].review.state, "TODO"), "0.2.0")
    end

    assert_raise Mix.Error, ~r/Windows/, fn ->
      UpgradePlan.validate!(
        put_in(plan.targets["windows"], plan.targets["macos_silicon"]),
        "0.2.0"
      )
    end
  end

  test "qualification rejects uncovered modules, migrations, native changes and wrong exact builds" do
    plan = hot(plan())

    report = %{
      from: %{"version" => "0.1.0", "build_id" => @build},
      identity_matches: true,
      changes: %{
        lemieux: %{added: [], removed: [], changed: ["Elixir.Lemieux.TUI"]},
        lmx: %{added: [], removed: [], changed: []}
      }
    }

    assert UpgradePlan.qualify!(plan, "macos_silicon", report) == :ok

    assert_raise Mix.Error, ~r/cover exactly/, fn ->
      UpgradePlan.qualify!(
        plan,
        "macos_silicon",
        put_in(report.changes.lmx.changed, ["Elixir.Lmx.Boot"])
      )
    end

    assert_raise Mix.Error, ~r/additions/, fn ->
      UpgradePlan.qualify!(
        plan,
        "macos_silicon",
        put_in(report.changes.lmx.added, ["Elixir.Lmx.New"])
      )
    end

    assert_raise Mix.Error, ~r/native assets/, fn ->
      UpgradePlan.qualify!(plan, "macos_silicon", %{report | identity_matches: false})
    end

    assert_raise Mix.Error, ~r/predecessor build/, fn ->
      UpgradePlan.qualify!(
        plan,
        "macos_silicon",
        put_in(report.from["build_id"], String.duplicate("b", 64))
      )
    end
  end

  @tag :tmp_dir
  test "draft records the actual artifact diff but cannot pass the release gate", %{tmp_dir: tmp} do
    old = Path.join(tmp, "old")
    new = Path.join(tmp, "new")

    for {root, version, bytes} <- [{old, "0.1.0", "old"}, {new, "0.2.0", "new"}] do
      File.mkdir_p!(Path.join([root, "releases", version]))
      File.mkdir_p!(Path.join([root, "lib", "lemieux-#{version}", "ebin"]))

      File.write!(
        Path.join([root, "lib", "lemieux-#{version}", "ebin", "Elixir.Lemieux.TUI.beam"]),
        bytes
      )

      info = %{"version" => version, "build_id" => @build, "target" => "macos_silicon"}
      File.write!(Path.join([root, "releases", version, "release.json"]), JSON.encode!(info))
    end

    report = UpgradePlan.report(old, new)
    assert report.changes.lemieux == %{added: [], removed: [], changed: ["Elixir.Lemieux.TUI"]}
    draft = UpgradePlan.draft(report)
    assert draft.targets["macos_silicon"].from_build == @build
    assert draft.targets["macos_silicon"].modules.lemieux == [Lemieux.TUI]
    assert_raise Mix.Error, ~r/unreviewed/, fn -> UpgradePlan.validate!(draft, "0.2.0") end
    # Mix --overwrite can leave prior metadata in a build tree. Boot data,
    # rather than wildcard order, selects the candidate being reviewed.
    File.mkdir_p!(Path.join([new, "releases", "0.1.0"]))

    File.write!(
      Path.join([new, "releases", "0.1.0", "release.json"]),
      JSON.encode!(%{"version" => "0.1.0"})
    )

    File.write!(Path.join(new, "releases/start_erl.data"), "17 0.2.0\n")
    assert UpgradePlan.metadata!(new)["version"] == "0.2.0"
  end

  test "initial decision is valid only when no stable release exists" do
    initial = %{
      plan()
      | from: nil,
        targets:
          Map.new(
            Lmx.Release.targets(),
            &{&1, %{mode: :initial, reason: "First public release."}}
          )
    }

    assert UpgradePlan.validate!(initial, "0.2.0", nil) == initial

    assert_raise Mix.Error, ~r/latest stable/, fn ->
      UpgradePlan.validate!(initial, "0.2.0", "0.1.0")
    end
  end

  @tag :tmp_dir
  test "previous artifacts are verified before extraction", %{tmp_dir: tmp} do
    archive = Path.join(tmp, "lmx_macos_silicon.tar.gz")
    sums = Path.join(tmp, "SHA256SUMS")
    destination = Path.join(tmp, "unpacked")
    :ok = :erl_tar.create(to_charlist(archive), [{~c"../escape", "bad"}], [:compressed])
    File.write!(sums, String.duplicate("0", 64) <> "  " <> Path.basename(archive))

    assert_raise Mix.Error, ~r/checksum/, fn ->
      UpgradePlan.unpack!(archive, sums, destination)
    end

    refute File.exists?(destination)
    digest = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
    File.write!(sums, digest <> "  " <> Path.basename(archive))
    assert_raise Mix.Error, ~r/unsafe/, fn -> UpgradePlan.unpack!(archive, sums, destination) end
    refute File.exists?(destination)
  end

  # The 0.8.1 release's Windows job stopped here: the published 0.8.0 Windows
  # archive carries the 0666 and 0777 modes Windows reports, and the gate
  # judged it by the updater's Unix rule (2026-10-06). The same bytes under a
  # Unix target's name are still refused.
  @tag :tmp_dir
  @tag :unix
  test "the previous Windows archive unpacks with the modes Windows reports", %{tmp_dir: tmp} do
    root = Path.join(tmp, "release")
    File.mkdir_p!(Path.join(root, "releases/0.1.0"))
    File.write!(Path.join(root, "releases/start_erl.data"), "17 0.1.0\n")
    info = %{"version" => "0.1.0", "target" => "windows", "build_id" => String.duplicate("a", 64)}
    File.write!(Path.join(root, "releases/0.1.0/release.json"), JSON.encode!(info))
    File.chmod!(Path.join(root, "releases/0.1.0/release.json"), 0o666)
    File.chmod!(Path.join(root, "releases/0.1.0"), 0o777)

    for name <- ["lmx_windows.tar.gz", "lmx_linux.tar.gz"] do
      archive = Path.join(tmp, name)

      :ok =
        :erl_tar.create(
          to_charlist(archive),
          [{~c"releases", to_charlist(Path.join(root, "releases"))}],
          [:compressed]
        )

      digest = :crypto.hash(:sha256, File.read!(archive)) |> Base.encode16(case: :lower)
      File.write!(Path.join(tmp, "SHA256SUMS-#{name}"), digest <> "  " <> name)
    end

    windows = Path.join(tmp, "unpacked-windows")

    assert :ok =
             UpgradePlan.unpack!(
               Path.join(tmp, "lmx_windows.tar.gz"),
               Path.join(tmp, "SHA256SUMS-lmx_windows.tar.gz"),
               windows
             )

    assert UpgradePlan.metadata!(windows)["target"] == "windows"

    assert_raise Mix.Error, ~r/unsafe/, fn ->
      UpgradePlan.unpack!(
        Path.join(tmp, "lmx_linux.tar.gz"),
        Path.join(tmp, "SHA256SUMS-lmx_linux.tar.gz"),
        Path.join(tmp, "unpacked-linux")
      )
    end
  end
end
