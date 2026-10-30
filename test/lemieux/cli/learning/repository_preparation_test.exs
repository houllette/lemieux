defmodule Lemieux.CLI.Learning.RepositoryPreparationTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Learning.RepositoryPreparation, as: Preparation

  @tag :tmp_dir
  test "patching a nested repository changes source and always removes private Git metadata", %{
    tmp_dir: root
  } do
    {_, 0} = System.cmd("git", ["-c", "init.templateDir=", "init", "-q", root])
    source = Path.join(root, "copy with spaces")
    File.mkdir!(source)
    File.write!(Path.join(source, "value.py"), "broken\n")
    patch = Path.join(root, "fix.patch")
    File.write!(patch, change("value.py", "broken", "fixed"))

    assert Preparation.apply_patch(source, patch) == ["value.py"]
    assert File.read!(Path.join(source, "value.py")) == "fixed\n"
    refute File.exists?(Path.join(source, ".git"))
    assert File.dir?(Path.join(root, ".git"))

    File.write!(patch, "not a patch")
    assert_raise RuntimeError, fn -> Preparation.apply_patch(source, patch) end
    assert File.read!(Path.join(source, "value.py")) == "fixed\n"
    refute File.exists?(Path.join(source, ".git"))
  end

  @tag :tmp_dir
  test "patch symlinks are refused before reading their target", %{tmp_dir: root} do
    source = Path.join(root, "source")
    File.mkdir!(source)
    outside = Path.join(root, "outside")
    File.write!(outside, "private bytes")
    patch = Path.join(root, "link.patch")

    File.write!(
      patch,
      "diff --git a/link b/link\nnew file mode 120000\n--- /dev/null\n+++ b/link\n@@ -0,0 +1 @@\n+../outside\n"
    )

    assert_raise ArgumentError, ~r/symlink/, fn -> Preparation.apply_patch(source, patch) end
    assert File.read!(outside) == "private bytes"
    refute File.exists?(Path.join(source, ".git"))
  end

  @tag :tmp_dir
  test "the oracle retains original verification bytes and the reference implementation", %{
    tmp_dir: root
  } do
    source = Path.join(root, "source")
    File.mkdir!(source)
    File.write!(Path.join(source, "value.py"), "broken\n")
    File.write!(Path.join(source, "README.md"), "original contract\n")
    patch = Path.join(root, "fix.patch")

    File.write!(
      patch,
      change("value.py", "broken", "fixed") <>
        change("README.md", "original contract", "changed instructions")
    )

    oracle = Path.join(root, "oracle")
    Preparation.project_oracle(source, oracle, patch, ["README.md"])
    assert File.read!(Path.join(oracle, "value.py")) == "fixed\n"
    assert File.read!(Path.join(oracle, "README.md")) == "original contract\n"
    assert File.read!(Path.join(source, "value.py")) == "broken\n"
  end

  test "pytest node IDs preserve files and select complete function families" do
    assert Preparation.pytest_selection([
             "tests/test_values.py::TestValues::test_round_trip[unicode]",
             "tests/test_values.py::TestValues::test_round_trip[ascii]",
             "tests/test_other.py::test_boundary"
           ]) ==
             {["tests/test_other.py", "tests/test_values.py"],
              ["test_round_trip", "test_boundary"]}

    assert Preparation.pytest_selection(["test_legacy"]) == {[], ["test_legacy"]}

    for selector <- [
          "../test.py::test_value",
          "/test.py::test_value",
          "tests\\test.py::test_value",
          "test.py::test_x or True",
          "test.py::test_x\naddopts=-x",
          "test.py::test_x[ok]\naddopts=-x",
          "tests//test.py::test_x"
        ] do
      assert_raise ArgumentError, fn -> Preparation.pytest_selection([selector]) end
    end

    assert_raise ArgumentError, fn -> Preparation.pytest_selection([]) end
  end

  @tag :tmp_dir
  test "archive validation happens before extraction and preserves ordinary file bytes", %{
    tmp_dir: root
  } do
    for {name, type} <- [{"../outside", ?0}, {"/absolute", ?0}, {"link", ?2}, {"hard", ?1}] do
      destination = Path.join(root, "source")

      assert_raise ArgumentError, fn ->
        Preparation.safe_extract(tar(name, "", type), destination)
      end

      refute File.exists?(destination)
    end

    destination = Path.join(root, "source")
    Preparation.safe_extract(tar("package/value.py", "value\n"), destination)
    assert File.read!(Path.join(destination, "package/value.py")) == "value\n"
  end

  @tag :tmp_dir
  test "duplicate archive names and file/directory collisions are rejected without partial extraction",
       %{tmp_dir: root} do
    for entries <- [
          [{"value.py", "first"}, {"value.py", "second"}],
          [{"package", "not a directory"}, {"package/value.py", "nested"}],
          [{"package/value.py", "nested"}, {"package", "not a directory"}]
        ] do
      destination = Path.join(root, "source")

      assert_raise ArgumentError, fn ->
        Preparation.safe_extract(archive(entries), destination)
      end

      refute File.exists?(destination)
    end
  end

  @tag :tmp_dir
  test "a valid archive cannot overwrite an existing destination", %{tmp_dir: root} do
    source = Path.join(root, "source")
    File.mkdir!(source)
    File.write!(Path.join(source, "value.py"), "existing bytes")

    assert_raise ArgumentError, ~r/destination already exists/, fn ->
      Preparation.safe_extract(archive([{"value.py", "replacement"}]), source)
    end

    assert File.read!(Path.join(source, "value.py")) == "existing bytes"
  end

  @tag :tmp_dir
  test "invalid identities and missing instances refuse before Docker or private output creation",
       %{tmp_dir: root} do
    opts = validation_fixture(root)

    for {overrides, message} <- [
          {[source_image: "mutable:latest"], ~r/immutable identities/},
          {[image: "mutable:latest"], ~r/immutable identities/},
          {[instance: "absent"], ~r/exactly once/}
        ] do
      assert_raise ArgumentError, message, fn ->
        Preparation.prepare(Keyword.merge(opts, overrides), fn _, _ ->
          flunk("Docker must not run")
        end)
      end

      refute File.exists?(opts[:output])
    end
  end

  @tag :tmp_dir
  test "prepared images must disable both bytecode and pytest cache writes before execution", %{
    tmp_dir: root
  } do
    opts = validation_fixture(root)

    for env <- [[], ["PYTHONDONTWRITEBYTECODE=1"], ["PYTEST_ADDOPTS=-p no:cacheprovider"]] do
      runner = fn
        ["docker", "image", "inspect", _image, "--format", "{{json .}}"], [] ->
          JSON.encode!(%{"Config" => %{"Env" => env}})

        argv, _opts ->
          flunk("unqualified image must not run: #{inspect(argv)}")
      end

      assert_raise ArgumentError, ~r/disable Python bytecode and pytest cache/, fn ->
        Preparation.prepare(opts, runner)
      end

      refute File.exists?(opts[:output])
    end
  end

  @tag :tmp_dir
  test "preparation keeps private patches out of source and binds the native template to its inputs",
       %{tmp_dir: root} do
    archive =
      archive([
        {"value.py", "broken\n"},
        {"README.md", "original contract\n"},
        {"tests/test_value.py", "original test\n"},
        {"conftest.py", "original root fixture\n"},
        {"tests/conftest.py", "nested fixture\n"}
      ])

    instance = %{
      "instance_id" => "project__project-1",
      "base_commit" => String.duplicate("a", 40),
      "repo" => "owner/project",
      "problem_statement" => "Repair the value.",
      "test_patch" =>
        change("tests/test_value.py", "original test", "private test") <>
          change("conftest.py", "original root fixture", "changed root fixture"),
      "patch" =>
        change("value.py", "broken", "fixed") <>
          change("README.md", "original contract", "changed instructions"),
      "FAIL_TO_PASS" => ["tests/test_value.py::test_value[one]"],
      "PASS_TO_PASS" => []
    }

    dataset = Path.join(root, "dataset.json")
    public = Path.join(root, "public.py")
    File.write!(dataset, JSON.encode!([instance]))
    File.write!(public, "public check\n")
    output = Path.join(root, "prepared")
    parent = self()

    # Docker and final control grading are external qualification, so this
    # offline test records their exact requests without claiming to run them.
    runner = fn argv, opts ->
      send(parent, {:preparation, argv, opts})

      case argv do
        ["docker", "image", "inspect" | _] ->
          JSON.encode!(%{
            "Config" => %{
              "Env" => ["PYTHONDONTWRITEBYTECODE=1", "PYTEST_ADDOPTS=-p no:cacheprovider"]
            }
          })

        ["docker", "run", "--rm", "--network", "none", "--read-only", "--entrypoint", "sh" | _] ->
          ""

        ["docker", "run", "--rm", "--network", "none", "--read-only", "--entrypoint", "git" | _] ->
          archive

        ["mix", "run", "scripts/freeze_learning_repository.exs", "--template", _path] ->
          ""
      end
    end

    opts = [
      dataset: dataset,
      instance: instance["instance_id"],
      source_image: "source@sha256:" <> String.duplicate("b", 64),
      image: "sha256:" <> String.duplicate("c", 64),
      public_check: public,
      output: output,
      repo: File.cwd!()
    ]

    assert Preparation.prepare(opts, runner) == Path.join(output, "manifest.json")
    template = output |> Path.join("template.json") |> File.read!() |> JSON.decode!()
    [task] = template["tasks"]
    assert template["metadata"]["source_archive_sha256"] == Lemieux.Contract.sha256(archive)
    assert template["metadata"]["dataset_sha256"] == Lemieux.Contract.sha256(File.read!(dataset))
    assert template["metadata"]["independent_confirmation"] == "not_run"
    assert File.read!(Path.join(task["source"], "value.py")) == "broken\n"
    assert File.read!(Path.join(task["source"], "tests/test_value.py")) == "original test\n"
    assert File.read!(Path.join(task["private_tests"], "tests/test_value.py")) == "private test\n"
    assert File.read!(Path.join(task["private_tests"], "tests/conftest.py")) == "nested fixture\n"

    assert File.read!(Path.join(task["private_tests"], "conftest.py")) ==
             "original root fixture\n"

    assert File.read!(Path.join(output, "oracle/value.py")) == "fixed\n"
    assert File.read!(Path.join(output, "oracle/README.md")) == "original contract\n"

    assert File.read!(Path.join(task["private_tests"], "pytest.ini")) ==
             "[pytest]\naddopts = -k \"test_value\"\n"

    assert task["immutable_paths"] ==
             ~w(README.md conftest.py qualification-contract.json qualification_pytest.ini test_qualification_public.py tests/conftest.py tests/test_value.py)

    contract =
      task["source"] |> Path.join("qualification-contract.json") |> File.read!() |> JSON.decode!()

    assert contract == %{"schema_version" => 1, "paths" => task["immutable_paths"]}
    refute File.exists?(Path.join(task["source"], "gold.private.patch"))
    refute File.exists?(Path.join(task["source"], "tests.private.patch"))
    # The mock is synchronous. Verify the complete boundary requests and order,
    # including which immutable image and Git commit supply the source. A fake
    # accepting any tail would also accept a different image or current HEAD.
    calls =
      for _ <- 1..4 do
        assert_received {:preparation, argv, options}
        {argv, options}
      end

    assert calls == [
             {["docker", "image", "inspect", opts[:image], "--format", "{{json .}}"], []},
             {[
                "docker",
                "run",
                "--rm",
                "--network",
                "none",
                "--read-only",
                "--entrypoint",
                "sh",
                opts[:image],
                "-c",
                "test ! -e /testbed && python3 -I -B -c 'import pytest'"
              ], [timeout_ms: 30_000]},
             {[
                "docker",
                "run",
                "--rm",
                "--network",
                "none",
                "--read-only",
                "--entrypoint",
                "git",
                opts[:source_image],
                "-C",
                "/testbed",
                "archive",
                instance["base_commit"]
              ], []},
             {[
                "mix",
                "run",
                "scripts/freeze_learning_repository.exs",
                "--template",
                Path.join(output, "template.json")
              ], [cwd: opts[:repo], timeout_ms: 1_200_000]}
           ]

    refute_received {:preparation, _, _}
  end

  defp validation_fixture(root) do
    dataset = Path.join(root, "dataset.json")

    File.write!(
      dataset,
      JSON.encode!([
        %{"instance_id" => "project__project-1", "base_commit" => String.duplicate("a", 40)}
      ])
    )

    [
      dataset: dataset,
      instance: "project__project-1",
      source_image: "source@sha256:" <> String.duplicate("b", 64),
      image: "sha256:" <> String.duplicate("c", 64),
      output: Path.join(root, "prepared")
    ]
  end

  defp archive(entries) do
    entries
    |> Enum.map(fn {name, bytes} ->
      entry = tar(name, bytes)
      binary_part(entry, 0, byte_size(entry) - 1024)
    end)
    |> IO.iodata_to_binary()
    |> Kernel.<>(:binary.copy(<<0>>, 1024))
  end

  defp change(name, before, value),
    do:
      "diff --git a/#{name} b/#{name}\n--- a/#{name}\n+++ b/#{name}\n@@ -1 +1 @@\n-#{before}\n+#{value}\n"

  # A small USTAR writer permits malicious members without invoking Python or
  # relying on a platform tar implementation to accept their names and types.
  defp tar(name, bytes, type \\ ?0) do
    fields = [
      pad(name, 100),
      octal(0o644, 8),
      octal(0, 8),
      octal(0, 8),
      octal(byte_size(bytes), 12),
      octal(0, 12),
      "        ",
      <<type>>,
      pad("/outside", 100),
      "ustar\0",
      "00",
      pad("", 32),
      pad("", 32),
      octal(0, 8),
      octal(0, 8),
      pad("", 155),
      pad("", 12)
    ]

    header = IO.iodata_to_binary(fields)
    <<prefix::binary-size(148), _::binary-size(8), rest::binary>> = header
    checksum = header |> :binary.bin_to_list() |> Enum.sum()

    prefix <>
      octal(checksum, 8) <>
      rest <>
      bytes <>
      :binary.copy(<<0>>, rem(512 - rem(byte_size(bytes), 512), 512)) <> :binary.copy(<<0>>, 1024)
  end

  defp pad(value, size), do: value <> :binary.copy(<<0>>, size - byte_size(value))

  defp octal(value, size),
    do: value |> Integer.to_string(8) |> String.pad_leading(size - 1, "0") |> Kernel.<>(<<0>>)
end
