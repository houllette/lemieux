defmodule CaptureExtension.SnapshotTest do
  use ExUnit.Case, async: true

  alias CaptureExtension.Snapshot

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    source = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(Path.join(source, "lib/nested"))
    File.write!(Path.join(source, "lib/nested/a.ex"), "a")
    File.write!(Path.join(source, "README.md"), "readme")

    %{source: source, destination: Path.join(tmp_dir, "fixture")}
  end

  test "copies the tree, keeping relative layout and file modes", context do
    script = Path.join(context.source, "check.sh")
    File.write!(script, "#!/bin/sh\nexit 1\n")
    File.chmod!(script, 0o755)

    assert {:ok, summary} = Snapshot.copy(context.source, context.destination, [])

    assert File.read!(Path.join(context.destination, "lib/nested/a.ex")) == "a"
    assert File.read!(Path.join(context.destination, "README.md")) == "readme"
    assert summary["files"] == 3

    assert summary["bytes"] ==
             byte_size("a") + byte_size("readme") + byte_size("#!/bin/sh\nexit 1\n")

    assert summary["skipped"] == []
    assert String.length(summary["digest"]) == 64

    %{mode: mode} = File.stat!(Path.join(context.destination, "check.sh"))
    assert Bitwise.band(mode, 0o100) == 0o100
  end

  test "skips build, dependency and version-control directories at any depth, and records them",
       context do
    for dir <- [".git", "_build", "deps", "node_modules", "lib/node_modules"] do
      File.mkdir_p!(Path.join(context.source, dir))
      File.write!(Path.join([context.source, dir, "big"]), String.duplicate("x", 100))
    end

    assert {:ok, summary} = Snapshot.copy(context.source, context.destination, [])

    refute File.exists?(Path.join(context.destination, ".git"))
    refute File.exists?(Path.join(context.destination, "lib/node_modules"))
    assert summary["files"] == 2

    assert Enum.sort(Enum.map(summary["skipped"], & &1["path"])) ==
             [".git", "_build", "deps", "lib/node_modules", "node_modules"]

    assert Enum.all?(summary["skipped"], &(&1["reason"] == "skipped_directory"))
  end

  test "skips a file over the per-file limit and records its size", context do
    File.write!(Path.join(context.source, "huge.bin"), String.duplicate("z", 2_048))

    assert {:ok, summary} =
             Snapshot.copy(context.source, context.destination, max_file_bytes: 1_024)

    refute File.exists?(Path.join(context.destination, "huge.bin"))

    assert [%{"path" => "huge.bin", "reason" => "too_large", "bytes" => 2_048}] =
             summary["skipped"]

    assert summary["files"] == 2
  end

  test "stops copying once the total budget is spent, keeping what fit", context do
    File.write!(Path.join(context.source, "zz-last.txt"), String.duplicate("q", 50))

    assert {:ok, summary} =
             Snapshot.copy(context.source, context.destination, max_total_bytes: 20)

    # Walk order is sorted: README.md (6) fits, lib/nested/a.ex (1) fits,
    # zz-last.txt (50) does not.
    assert File.exists?(Path.join(context.destination, "README.md"))
    refute File.exists?(Path.join(context.destination, "zz-last.txt"))
    assert [%{"path" => "zz-last.txt", "reason" => "over_budget"}] = summary["skipped"]
    assert summary["bytes"] == 7
  end

  test "never follows symlinks", context do
    File.ln_s!(context.source, Path.join(context.source, "loop"))
    File.ln_s!(Path.join(context.source, "README.md"), Path.join(context.source, "alias.md"))

    assert {:ok, summary} = Snapshot.copy(context.source, context.destination, [])

    refute File.exists?(Path.join(context.destination, "loop"))
    refute File.exists?(Path.join(context.destination, "alias.md"))

    assert Enum.sort(Enum.map(summary["skipped"], & &1["path"])) == ["alias.md", "loop"]
    assert Enum.all?(summary["skipped"], &(&1["reason"] == "symlink"))
  end

  test "excludes the directories it is told to, so a drafts directory inside the workspace is not copied into itself",
       context do
    drafts = Path.join(context.source, ".lmx/drafts")
    File.mkdir_p!(Path.join(drafts, "case_old/fixture"))
    File.write!(Path.join(drafts, "case_old/fixture/x"), "x")
    File.mkdir_p!(Path.join(context.source, ".lmx"))
    File.write!(Path.join(context.source, ".lmx/harness.json"), "{}")

    assert {:ok, summary} = Snapshot.copy(context.source, context.destination, exclude: [drafts])

    assert File.exists?(Path.join(context.destination, ".lmx/harness.json"))
    refute File.exists?(Path.join(context.destination, ".lmx/drafts"))
    assert [%{"path" => ".lmx/drafts", "reason" => "excluded"}] = summary["skipped"]
  end

  test "never copies files named like credentials, at any depth, and records each as secret",
       context do
    secrets = [
      ".env",
      ".env.local",
      ".envrc",
      "deploy/id_ed25519",
      "certs/server.pem",
      "certs/server.key",
      "config/prod.secret.exs",
      ".netrc",
      "erl_crash.dump",
      "keys/Signing.PEM",
      ".aws/credentials",
      "gcloud/application_default_credentials.json",
      # lmx's saved keys, in a session started in the home directory.
      ".lmx/config.json"
    ]

    kept = [".env.example", "lib/keyboard.ex", "lib/env.ex", "app/config.json"]

    for path <- secrets ++ kept do
      File.mkdir_p!(Path.dirname(Path.join(context.source, path)))
      File.write!(Path.join(context.source, path), "value")
    end

    assert {:ok, summary} = Snapshot.copy(context.source, context.destination, [])

    for path <- secrets, do: refute(File.exists?(Path.join(context.destination, path)), path)
    for path <- kept, do: assert(File.exists?(Path.join(context.destination, path)), path)

    assert Enum.sort(Enum.map(summary["skipped"], & &1["path"])) == Enum.sort(secrets)
    assert Enum.all?(summary["skipped"], &(&1 == %{"path" => &1["path"], "reason" => "secret"}))
  end

  test "skip_secrets: false copies a curated tree as it is", context do
    File.write!(Path.join(context.source, ".env"), "FIXTURE=1\n")

    assert {:ok, summary} =
             Snapshot.copy(context.source, context.destination, skip_secrets: false)

    assert File.read!(Path.join(context.destination, ".env")) == "FIXTURE=1\n"
    assert summary["skipped"] == []
  end

  # The same names `Lemieux.Benchmark.SecretFiles` keeps out of a corpus
  # fixture, so a capture draft and a promoted case agree on what is missing.
  test "secret?/1 judges the last segment of the name, whatever its case" do
    for name <-
          ~w(.env .env.production .env.sample .ENV .envrc mise.local.toml .mise.local.toml
             id_rsa id_rsa.pub ID_ED25519 tls.key cert.pem Server.PEM AuthKey_ABC123.p8
             putty.ppk app.jks release.keystore .netrc _netrc .npmrc .pypirc .pgpass
             .git-credentials credentials .aws/credentials credentials.json
             application_default_credentials.json serviceAccountKey.json
             my-project-service-account.json client_secret_123.json prod.secret.exs
             erl_crash.dump nested/dir/.env) do
      assert Snapshot.secret?(name), name
    end

    for name <-
          ~w(.env.example .ENV.EXAMPLE env.ex README.md keys.ex lib/keys.ex credentials.ex
             credentials_test.exs service_account.ex keymap.json environment.json config.json
             .envoy .gitignore) do
      refute Snapshot.secret?(name), name
    end
  end

  test "the digest changes when a copied file changes", context do
    assert {:ok, %{"digest" => before}} = Snapshot.copy(context.source, context.destination, [])
    File.write!(Path.join(context.source, "README.md"), "changed")

    assert {:ok, %{"digest" => after_change}} =
             Snapshot.copy(context.source, context.destination <> "2", [])

    refute before == after_change
  end

  test "a missing source is an error, not an empty fixture", context do
    assert {:error, {:source_not_directory, _}} =
             Snapshot.copy(Path.join(context.source, "nope"), context.destination, [])
  end
end
