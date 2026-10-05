defmodule Lemieux.ExtensionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Contract
  alias Lemieux.Learning.Extension.Export

  @moduletag :tmp_dir

  setup context do
    root = Path.join(context.tmp_dir, "source")
    File.mkdir_p!(Path.join(root, "lib"))
    File.write!(Path.join(root, "mix.exs"), "# exact Mix source\n")
    File.write!(Path.join(root, "lib/review.ex"), "# exact agent source\n")
    File.write!(Path.join(root, ".env"), "DO_NOT_EXPORT=private")

    manifest = %{
      "schema_version" => 1,
      "module" => "Example.Review",
      "files" => ["mix.exs", "lib/review.ex"]
    }

    File.write!(Path.join(root, "lemieux-extension.json"), JSON.encode!(manifest))
    %{root: root, destination: Path.join(context.tmp_dir, "export"), manifest: manifest}
  end

  test "exports exact explicit sources and an unqualified integrity receipt", context do
    assert {:ok, receipt} = Export.export(context.root, context.destination)
    assert receipt["qualification"] == "unassessed"
    assert receipt["module"] == "Example.Review"
    assert File.read!(Path.join(context.destination, "lib/review.ex")) == "# exact agent source\n"
    assert File.read!(Path.join(context.destination, "mix.exs")) == "# exact Mix source\n"
    refute File.exists?(Path.join(context.destination, ".env"))
    assert :ok = Export.verify(context.destination)

    File.write!(Path.join(context.destination, "lib/review.ex"), "# changed\n")

    assert {:error, {:file_digest_mismatch, "lib/review.ex"}} =
             Export.verify(context.destination)
  end

  test "refuses existing destinations without changing their contents", context do
    File.mkdir!(context.destination)
    File.write!(Path.join(context.destination, "keep"), "user work")
    assert {:error, :destination_exists} = Export.export(context.root, context.destination)
    assert File.read!(Path.join(context.destination, "keep")) == "user work"
  end

  test "verification rejects added executable source and forged qualification", context do
    assert {:ok, receipt} = Export.export(context.root, context.destination)
    extra = Path.join(context.destination, "lib/extra.ex")
    File.write!(extra, "# unrecorded executable source")
    assert {:error, :extension_file_set_mismatch} = Export.verify(context.destination)
    File.rm!(extra)

    File.mkdir!(Path.join(context.destination, "config"))
    File.write!(Path.join(context.destination, "config/config.exs"), "# added executable config")
    assert {:error, :extension_file_set_mismatch} = Export.verify(context.destination)
    File.rm_rf!(Path.join(context.destination, "config"))

    File.ln_s!(context.root, Path.join(context.destination, "lib/alias"))
    assert {:error, {:unsafe_package_path, "lib/alias"}} = Export.verify(context.destination)
    File.rm!(Path.join(context.destination, "lib/alias"))

    receipt = Map.put(receipt, "qualification", "qualified")
    receipt = Map.put(receipt, "sha256", Contract.digest(receipt, ["sha256"]))

    File.write!(
      Path.join(context.destination, "lemieux-extension-export.json"),
      JSON.encode!(receipt)
    )

    assert {:error, :invalid_extension_receipt} = Export.verify(context.destination)
  end

  test "rejects traversal, duplicate entries and symlink sources before creating output",
       context do
    for path <- [
          "",
          "../outside.ex",
          "/tmp/outside.ex",
          "lib/../mix.exs",
          ".env",
          "lemieux-extension-export.json"
        ] do
      write_manifest(context, ["mix.exs", "lib/review.ex", path])
      assert {:error, _reason} = Export.export(context.root, context.destination)
      refute File.exists?(context.destination)
    end

    write_manifest(context, ["mix.exs", "lib/review.ex", "lib/review.ex"])
    assert {:error, :invalid_package_files} = Export.export(context.root, context.destination)

    File.ln_s!(Path.join(context.root, ".env"), Path.join(context.root, "lib/leak.ex"))
    write_manifest(context, ["mix.exs", "lib/review.ex", "lib/leak.ex"])

    assert {:error, {:unsafe_package_path, "lib/leak.ex"}} =
             Export.export(context.root, context.destination)

    refute File.exists?(context.destination)
  end

  defp write_manifest(context, files) do
    File.write!(
      Path.join(context.root, "lemieux-extension.json"),
      JSON.encode!(%{context.manifest | "files" => files})
    )
  end
end
