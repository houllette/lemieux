defmodule Lemieux.TUI.LinksOpenTest do
  @moduledoc """
  A click on a file reference opens it as text or shows it in its folder.
  A plain click used to hand any existing file to `open`, `explorer.exe` or
  `xdg-open`, so a model-written `.command` or `.bat` ran with the person's
  full rights, outside the approval mode and the sandbox.
  """
  use ExUnit.Case, async: true

  import Lemieux.TUI.TestSupport

  alias Lemieux.TUI
  alias Lemieux.TUI.Links

  @moduletag :tmp_dir

  @mac {:unix, :darwin}
  @windows {:win32, :nt}
  @linux {:unix, :linux}

  defp file(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  test "a script or bundle type is refused on every platform, and nothing runs", %{
    tmp_dir: dir
  } do
    marker = Path.join(dir, "ran")

    for name <- ~w(fix.command fix.sh fix.bat fix.ps1 fix.scpt fix.terminal fix.webloc
                   fix.desktop fix.exe fix.jar fix.app fix.vbs fix.lnk) do
      path = file(dir, name, "#!/bin/sh\ntouch #{marker}\n")

      for os <- [@mac, @windows, @linux] do
        assert {:refused, why} = Links.opener_command(path, os)
        assert why =~ "#{Path.extname(name)} files can run code, so lmx does not open them"
      end
    end

    assert {:error, {:refused, _why}} = Links.open(Path.join(dir, "fix.command"))
    refute File.exists?(marker)
  end

  test "the name is checked in either case, and through a symlink", %{tmp_dir: dir} do
    upper = file(dir, "RUN.COMMAND", "echo hi\n")
    assert {:refused, _why} = Links.opener_command(upper, @mac)

    target = file(dir, "run.command", "echo hi\n")
    link = Path.join(dir, "notes.md")
    File.ln_s!(target, link)
    assert {:refused, why} = Links.opener_command(link, @mac)
    assert why =~ ".command files"
  end

  test "every link in a chain is judged, not just the first", %{tmp_dir: dir} do
    file(dir, "run.command", "echo hi\n")
    File.ln_s!("run.command", Path.join(dir, "a.md"))
    notes = Path.join(dir, "notes.md")
    File.ln_s!("a.md", notes)

    for os <- [@mac, @windows, @linux] do
      assert {:refused, why} = Links.opener_command(notes, os)
      assert why =~ ".command files"
    end
  end

  test "a link through a linked directory and .. is followed where it lands", %{tmp_dir: dir} do
    elsewhere = Path.join(dir, "elsewhere")
    File.mkdir_p!(Path.join(elsewhere, "inner"))
    file(elsewhere, "run.command", "echo hi\n")
    File.ln_s!("run.command", Path.join(elsewhere, "a.md"))

    repo = Path.join(dir, "repo")
    File.mkdir_p!(repo)
    File.ln_s!(Path.join(elsewhere, "inner"), Path.join(repo, "d"))
    # Read as text, `d/../a.md` is this harmless `repo/a.md`; the kernel goes
    # up from `elsewhere/inner` and reaches the link to `run.command`.
    file(repo, "a.md", "decoy\n")
    notes = Path.join(repo, "notes.md")
    File.ln_s!("d/../a.md", notes)

    assert {:refused, why} = Links.opener_command(notes, @linux)
    assert why =~ ".command files"
  end

  test "on Linux a #! script is shown in its folder, whatever its name", %{tmp_dir: dir} do
    script = file(dir, "deploy", "#!/bin/sh\nrm -rf build\n")

    assert Links.opener_command(script, @linux) == {"xdg-open", [dir]}
    assert Links.opener_command(script, @mac) == {"open", ["-t", script]}
  end

  test "text opens in a text editor, whatever its association", %{tmp_dir: dir} do
    notes = file(dir, "notes.txt", "plain text, with ünïcode\n")
    script = file(dir, "tool.py", "print('hi')\n")

    assert Links.opener_command(notes, @mac) == {"open", ["-t", notes]}
    assert Links.opener_command(script, @mac) == {"open", ["-t", script]}

    assert Links.opener_command(notes, @windows) ==
             {"notepad.exe", [String.replace(notes, "/", "\\")]}

    assert Links.opener_command(notes, @linux) == {"xdg-open", [notes]}
  end

  test "on Linux, source a desktop may run and web pages are shown in their folder", %{
    tmp_dir: dir
  } do
    for name <- ~w(tool.py page.html app.js) do
      path = file(dir, name, "text\n")
      assert Links.opener_command(path, @linux) == {"xdg-open", [dir]}
    end
  end

  test "anything that is not text is shown in its folder", %{tmp_dir: dir} do
    image = file(dir, "chart.png", <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13>>)

    assert Links.opener_command(image, @mac) == {"open", ["-R", image]}

    assert Links.opener_command(image, @windows) ==
             {"explorer.exe", ["/select," <> String.replace(image, "/", "\\")]}

    assert Links.opener_command(image, @linux) == {"xdg-open", [dir]}
  end

  test "web addresses still open in the browser" do
    assert Links.opener_command("https://example.com/run.command", @mac) ==
             {"open", ["https://example.com/run.command"]}

    assert Links.opener_command("https://example.com", @windows) ==
             {"explorer.exe", ["https://example.com"]}
  end

  test "a refused file is a hint on the status row, not a transcript error" do
    state = tui(lines: [{:model, "Next: scripts/fix.command"}])

    assert {:noreply, refused} =
             TUI.handle_info(
               {:open_link_result,
                {:error,
                 {:refused,
                  ".command files can run code, so lmx does not open them; open it yourself if you meant to"}}},
               state
             )

    assert status_row(refused) =~ "not opened · .command files can run code"
  end
end
