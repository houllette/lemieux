defmodule Lmx.NoticesTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lmx.Notices

  @crates File.read!("notices/crates.txt")

  # The crate list is committed and reviewed, so a dependency bump must not
  # leave it describing a NIF the archive no longer carries.
  test "the committed crate notices describe the bundled ex_ratatui" do
    version = :ex_ratatui |> Application.spec(:vsn) |> to_string()
    dir = Mix.Project.deps_paths()[:ex_ratatui]

    assert Notices.field(@crates, "ex_ratatui") == version
    assert Notices.check_crates(@crates, version, dir) == :ok

    assert_raise Mix.Error, ~r/describes ex_ratatui/, fn ->
      Notices.check_crates(@crates, version <> ".1", dir)
    end

    changed = String.replace(@crates, ~r/^Cargo.lock sha256: .*$/m, "Cargo.lock sha256: 00")

    assert_raise Mix.Error, ~r/Cargo.lock differs/, fn ->
      Notices.check_crates(changed, version, dir)
    end
  end

  test "every license the crate notices use has its text" do
    for id <- @crates |> Notices.field("Licenses") |> String.split(", ") do
      assert File.regular?("notices/licenses/#{id}.txt"), "no notices/licenses/#{id}.txt"
    end
  end

  # The same application set `mix release` computes, so a dependency that
  # arrives without license information fails here before it fails a build.
  test "the release's own applications all resolve to notices" do
    release = Mix.Release.from_config!(:lmx, Mix.Project.config(), [])
    deps = Mix.Project.deps_paths()
    inventory = Notices.inventory(release.applications, deps, release.version)
    text = Notices.render(inventory)

    package_names = Enum.map(inventory.packages, & &1.name)
    assert "req_llm" in package_names
    assert "ex_ratatui" in package_names
    refute Enum.any?(package_names, &(&1 in ~w(lmx lemieux lemieux_jev_compaction)))
    refute Enum.any?(package_names, &(&1 in ~w(kernel stdlib elixir logger)))

    for package <- inventory.packages do
      assert text =~ "\n#{package.name} #{package.version}\nLicense: "
    end

    assert text =~ "Erlang/OTP #{inventory.otp.version}"
    assert text =~ "Copyright Ericsson AB"
    assert text =~ "PCRE2"
    assert text =~ "Elixir #{System.version()}"
    assert text =~ "OpenSSL"
    assert text =~ "Copyright (c) 2017 Kamil Lelonek"
    assert text =~ "Rust crates in the ex_ratatui terminal NIF"
    assert text =~ "--- Apache-2.0 ---"
    assert text =~ "--- MIT ---"
    assert text =~ "Copyright (c) 2009 The Go Authors"
  end

  describe "packages" do
    @describetag :tmp_dir

    test "a package without license text needs a reviewed supplement", %{tmp_dir: dir} do
      write_package(dir, "MIT")

      assert_raise Mix.Error, ~r/ships no license text/, fn ->
        Notices.package(:unreviewed_fixture, "1.0.0", dir)
      end

      File.write!(Path.join(dir, "LICENSE"), "Copyright (c) 2026 Someone\n")
      package = Notices.package(:unreviewed_fixture, "1.0.0", dir)
      assert package.licenses == ["MIT"]
      assert package.texts == [{"LICENSE", "Copyright (c) 2026 Someone\n"}]
    end

    test "an Apache-2.0 package is covered by the license text itself", %{tmp_dir: dir} do
      write_package(dir, "Apache 2.0")
      package = Notices.package(:apache_fixture, "1.0.0", dir)
      assert package.licenses == ["Apache-2.0"]
      assert package.texts == []
    end

    test "an unknown license name stops the build", %{tmp_dir: dir} do
      write_package(dir, "Some Custom License")

      assert_raise Mix.Error, ~r/no SPDX identifier/, fn ->
        Notices.package(:custom_fixture, "1.0.0", dir)
      end
    end

    test "a REUSE LICENSES directory is read", %{tmp_dir: dir} do
      write_package(dir, "MIT")
      File.mkdir_p!(Path.join(dir, "LICENSES"))
      File.write!(Path.join(dir, "LICENSES/MIT.txt"), "MIT text")
      package = Notices.package(:reuse_fixture, "1.0.0", dir)
      assert package.texts == [{"LICENSES/MIT.txt", "MIT text"}]
    end
  end

  # The OpenSSL notice used to say every Linux and macOS build linked it
  # statically, which depends on the Erlang/OTP a build copies.
  describe "OpenSSL linkage" do
    @describetag :tmp_dir

    test "is read from the crypto NIF's dynamic libraries" do
      otool = """
      /release/lib/crypto-5.9/priv/lib/crypto.so:
      \t/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib (compatibility version 3.0.0, current version 3.5.7)
      \t/usr/lib/libSystem.B.dylib (compatibility version 1.0.0, current version 1351.0.0)
      """

      assert Notices.linked_libraries(otool, :otool) == ["libcrypto.3.dylib", "libSystem.B.dylib"]

      readelf = """

      Dynamic section at offset 0x5f9d8 contains 27 entries:
        Tag        Type                         Name/Value
       0x0000000000000001 (NEEDED)             Shared library: [libcrypto.so.3]
       0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
       0x000000000000000e (SONAME)             Library soname: [crypto.so]
      """

      assert Notices.linked_libraries(readelf, :readelf) == ["libcrypto.so.3", "libc.so.6"]
    end

    test "is unknown for a release without a crypto NIF", %{tmp_dir: dir} do
      assert Notices.openssl_linkage(dir) == :unknown
    end

    # The running Erlang/OTP's own NIF, under a release-shaped path. Which
    # answer is right depends on how this OTP was built; on a Unix host with
    # otool or readelf it must be an answer, and a dynamic one must name
    # OpenSSL.
    test "answers for this host's crypto NIF", %{tmp_dir: dir} do
      nif = Path.join(:code.priv_dir(:crypto), "lib/crypto.so")
      tool = if match?({:unix, :darwin}, :os.type()), do: "otool", else: "readelf"

      if File.regular?(nif) and System.find_executable(tool) do
        copy = Path.join(dir, "lib/crypto-0.0.0/priv/lib/crypto.so")
        File.mkdir_p!(Path.dirname(copy))
        File.cp!(nif, copy)

        linkage = Notices.openssl_linkage(dir)

        assert linkage == :static or match?({:dynamic, "libcrypto" <> _}, linkage) or
                 match?({:dynamic, "libssl" <> _}, linkage),
               "unexpected linkage #{inspect(linkage)}"
      end
    end

    # Release archives carry their own OpenSSL on Linux and macOS. A
    # candidate whose NIF loads the build machine's would fail to load crypto
    # on a clean system, and the macOS runners, which have Homebrew's
    # OpenSSL, would not have noticed.
    test "a release candidate that loads the system's OpenSSL stops the build" do
      assert_raise Mix.Error, ~r/loads libcrypto\.so\.3 from the build machine/, fn ->
        Notices.check_linkage!({:dynamic, "libcrypto.so.3"}, true)
      end

      output =
        capture_io(fn ->
          assert Notices.check_linkage!({:dynamic, "libcrypto.3.dylib"}, false) == :ok
        end)

      assert output =~ "warning: this release's crypto NIF loads libcrypto.3.dylib"

      for candidate? <- [true, false], linkage <- [:static, :unknown] do
        assert capture_io(fn -> Notices.check_linkage!(linkage, candidate?) end) == ""
      end
    end

    test "decides what the notice claims" do
      base = minimal_inventory()

      static = Notices.render(Map.put(base, :openssl_linkage, :static))
      assert static =~ "This build links it into that NIF statically"

      dynamic = Notices.render(Map.put(base, :openssl_linkage, {:dynamic, "libcrypto.so.3"}))
      assert dynamic =~ "loads it from the system (libcrypto.so.3)"
      refute dynamic =~ "statically"

      unknown = Notices.render(base)
      refute unknown =~ "statically"
      refute unknown =~ "from the system"
      assert unknown =~ "uses OpenSSL through its NIF\n(lib/crypto-*/priv/lib).\n"
    end
  end

  test "identical license files are printed once" do
    inventory = %{
      version: "0.1.0",
      target: "linux",
      otp: %{version: "29.0.2", erts: "17.0.2"},
      otp_apps: [kernel: "11.0.2"],
      elixir: %{version: "1.20.2"},
      elixir_apps: [elixir: "1.20.2"],
      openssl: "OpenSSL 3.5.7",
      packages: [
        %{
          name: "one",
          version: "1.0.0",
          licenses: ["MIT"],
          link: nil,
          texts: [{"LICENSE", "same"}]
        },
        %{
          name: "two",
          version: "2.0.0",
          licenses: ["MIT"],
          link: nil,
          texts: [{"LICENSE", "same"}]
        }
      ],
      crates: nil,
      odu?: false
    }

    text = Notices.render(inventory)
    assert text =~ "--- LICENSE ---\n\nsame\n"
    assert text =~ "--- LICENSE: identical to the text shown for one 1.0.0 ---"
    refute text =~ "Rust crates"
    refute text =~ "Go runtime"
  end

  defp minimal_inventory do
    %{
      version: "0.1.0",
      target: "linux",
      otp: %{version: "29.0.2", erts: "17.0.2"},
      otp_apps: [kernel: "11.0.2"],
      elixir: %{version: "1.20.2"},
      elixir_apps: [elixir: "1.20.2"],
      openssl: "OpenSSL 3.5.7",
      packages: [],
      crates: nil,
      odu?: false
    }
  end

  defp write_package(dir, license) do
    File.write!(
      Path.join(dir, "hex_metadata.config"),
      ~s|{<<"licenses">>,[<<"#{license}">>]}.\n{<<"links">>,[]}.\n|
    )
  end
end
