defmodule VerifierExtension.DiscoveryTest do
  use ExUnit.Case, async: true

  alias VerifierExtension.Discovery

  @moduletag :tmp_dir

  defp put(dir, path, contents) do
    full = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(full))
    File.write!(full, contents)
  end

  test "an explicit verify_command wins over every convention", %{tmp_dir: dir} do
    put(dir, "tests/run.sh", "exit 0\n")

    assert {:ok, %{command: "sh scripts/verify.sh", discovered_from: "verify_command"}} =
             Discovery.discover(dir, verify_command: "sh scripts/verify.sh")
  end

  test "tests/run.sh is run with sh", %{tmp_dir: dir} do
    put(dir, "tests/run.sh", "exit 0\n")

    assert {:ok, %{command: "sh tests/run.sh", discovered_from: "tests/run.sh"}} =
             Discovery.discover(dir)
  end

  test "a Makefile test target beats a check target, and either is used", %{tmp_dir: dir} do
    put(dir, "Makefile", "check:\n\t./check\n\ntest:\n\t./run\n")
    assert {:ok, %{command: "make test", discovered_from: "Makefile"}} = Discovery.discover(dir)

    put(dir, "Makefile", ".PHONY: check\ncheck: build\n\t./check\n")
    assert {:ok, %{command: "make check", discovered_from: "Makefile"}} = Discovery.discover(dir)
  end

  test "a Makefile without a test or check target is not a verification command",
       %{tmp_dir: dir} do
    put(dir, "Makefile", "build:\n\tcc -o app app.c\n\ntestdata:\n\t./gen\n")
    assert :none = Discovery.discover(dir)
  end

  test "mix.exs means mix test", %{tmp_dir: dir} do
    put(dir, "mix.exs", "defmodule P.MixProject do\nend\n")
    assert {:ok, %{command: "mix test", discovered_from: "mix.exs"}} = Discovery.discover(dir)
  end

  test "a package.json test script means npm test", %{tmp_dir: dir} do
    put(dir, "package.json", ~s({"name":"p","scripts":{"test":"node --test"}}))

    assert {:ok, %{command: "npm test", discovered_from: "package.json"}} =
             Discovery.discover(dir)
  end

  test "npm's placeholder test script and a missing script are not commands", %{tmp_dir: dir} do
    put(
      dir,
      "package.json",
      ~s({"scripts":{"test":"echo \\"Error: no test specified\\" && exit 1"}})
    )

    assert :none = Discovery.discover(dir)

    put(dir, "package.json", ~s({"name":"p"}))
    assert :none = Discovery.discover(dir)

    put(dir, "package.json", "not json")
    assert :none = Discovery.discover(dir)
  end

  test "conventions are tried in a fixed order", %{tmp_dir: dir} do
    put(dir, "package.json", ~s({"scripts":{"test":"node --test"}}))
    put(dir, "mix.exs", "")
    put(dir, "Makefile", "test:\n\t./run\n")
    put(dir, "tests/run.sh", "exit 0\n")

    assert {:ok, %{discovered_from: "tests/run.sh"}} = Discovery.discover(dir)
    File.rm!(Path.join(dir, "tests/run.sh"))
    assert {:ok, %{discovered_from: "Makefile"}} = Discovery.discover(dir)
    File.rm!(Path.join(dir, "Makefile"))
    assert {:ok, %{discovered_from: "mix.exs"}} = Discovery.discover(dir)
    File.rm!(Path.join(dir, "mix.exs"))
    assert {:ok, %{discovered_from: "package.json"}} = Discovery.discover(dir)
  end

  test "check.sh is the corpus grader and is never discovered", %{tmp_dir: dir} do
    put(dir, "check.sh", "#!/bin/sh\necho grader\n")
    assert :none = Discovery.discover(dir)
  end

  test "an empty workspace has no command", %{tmp_dir: dir} do
    assert :none = Discovery.discover(dir)
  end
end
