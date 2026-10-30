defmodule CIScriptsTest do
  use ExUnit.Case, async: true

  @root Path.expand("..", __DIR__)
  @private_name Base.decode64!("Q2hvcnVz")

  @tag :tmp_dir
  test "public wording gate accepts clean content and honors its allowlist", %{tmp_dir: root} do
    assert {output, 0} =
             public_text(Path.join(root, "clean"), %{"docs/a.md" => "An embedding host.\n"})

    assert output =~ "no listed private names"

    assert {_, 0} =
             public_text(Path.join(root, "allowed"), %{
               "docs/a.md" => "Mentions #{@private_name}.\n",
               "scripts/public_text_allowlist.txt" =>
                 "# The page quotes it on purpose.\ndocs/a.md\n"
             })
  end

  @tag :tmp_dir
  test "public wording gate reports private names in any case and inside larger words", %{
    tmp_dir: root
  } do
    assert {output, 1} =
             public_text(root, %{
               "lib/a.ex" => "# used by #{String.upcase(@private_name)}\n",
               "notes.txt" => "see #{@private_name}Host\n"
             })

    assert output =~ "appears on 2 lines in 2 files"
    assert output =~ "lib/a.ex:1:"
  end

  test "gate and test source do not spell the name they look for" do
    spelled =
      @private_name
      |> String.downcase()
      |> String.graphemes()
      |> Enum.join("[^a-z]*")
      |> Regex.compile!()

    for name <- ["scripts/check_public_text.sh", "test/ci_scripts_test.exs"] do
      refute Regex.match?(spelled, @root |> Path.join(name) |> File.read!() |> String.downcase())
    end
  end

  @tag :tmp_dir
  test "a failed public wording search is an error", %{tmp_dir: root} do
    assert {output, 2} =
             public_text(root, %{
               "docs/a.md" => "Mentions #{@private_name}.\n",
               "scripts/public_text_allowlist.txt" => "../outside\n"
             })

    assert output =~ "git grep failed"
    refute output =~ "check_public_text: no "
  end

  @tag :tmp_dir
  test "launch wording checks Markdown and Elixir but exempts historical changelog entries", %{
    tmp_dir: root
  } do
    assert {output, 1} =
             public_text(root, %{
               "README.md" => "This repository is currently private.\n",
               "lib/b.ex" => "# Repository access is required while the project is private.\n",
               "CHANGELOG.md" => "- No public binary before 0.1.0.\n",
               "scripts/x.sh" => "# not advertised yet\n"
             })

    assert output =~ "Launch-state wording remains on 2 lines"
    refute output =~ "CHANGELOG.md"
    refute output =~ "scripts/x.sh"
  end

  @tag :tmp_dir
  test "the checked-in toolchain has static build pins", %{tmp_dir: root} do
    assert {_, 0} = static_pins(root, File.read!(Path.join(@root, ".tool-versions")))
  end

  @tag :tmp_dir
  test "static pins reject unsupported OTP releases and mismatched Elixir builds", %{
    tmp_dir: root
  } do
    assert {output, 1} = static_pins(root, "erlang 29.0.99\nelixir 1.20.4-otp-29\n")
    assert output =~ "no pinned SHA-256 for otp_src_29.0.99.tar.gz"
    assert {output, 1} = static_pins(root, "erlang 29.1.1\nelixir 1.20.4-otp-28\n")
    assert output =~ "not built for OTP 29"
  end

  defp public_text(root, files) do
    for {name, bytes} <- files do
      path = Path.join(root, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    File.mkdir_p!(Path.join(root, "scripts"))

    File.cp!(
      Path.join(@root, "scripts/check_public_text.sh"),
      Path.join(root, "scripts/check_public_text.sh")
    )

    {_, 0} = System.cmd("git", ["-c", "init.templateDir=", "init", "-q", root])
    {_, 0} = System.cmd("git", ["-C", root, "add", "-A"])
    System.cmd("sh", [Path.join(root, "scripts/check_public_text.sh")], stderr_to_stdout: true)
  end

  defp static_pins(root, versions) do
    File.mkdir_p!(Path.join(root, "scripts"))

    File.cp!(
      Path.join(@root, "scripts/build-static-otp.sh"),
      Path.join(root, "scripts/build-static-otp.sh")
    )

    File.write!(Path.join(root, ".tool-versions"), versions)

    System.cmd("bash", [Path.join(root, "scripts/build-static-otp.sh"), "--check-pins"],
      stderr_to_stdout: true
    )
  end
end
