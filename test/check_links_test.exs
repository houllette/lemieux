Code.require_file("../scripts/support/check_links.exs", __DIR__)

defmodule CheckLinksTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureIO

  alias Lemieux.Scripts.CheckLinks

  @files %{
    "README.md" => "# Read me\n\n[guide](docs/guide.md#second-part) [root](/docs/guide.md)\n",
    "docs/guide.md" =>
      "# Guide\n\n## Second part\n\n[here](#guide) [examples](../examples/) [image](../assets/pic.png)\n\n[later]: guide.md#second-part\n\nSee https://github.com/houllette/lemieux/blob/main/docs/guide.md#second-part.\n\n```sh\n[not a link](nowhere.md)\n```\n",
    "examples/run.exs" => "IO.puts(:ok)\n",
    "assets/pic.png" => "not really a picture\n",
    "eval/corpus/fixture/README.md" => "[broken on purpose](missing.md)\n"
  }

  test "heading anchors preserve rendered text, Unicode, duplicate headings and explicit anchors" do
    text =
      "# Title\n\n## The `mix lmx` task\n\n## Replacing a tool's receipt\n\n## Q&A: what's [new](x.md)?\n\n## Title\n\nSetext heading\n--------------\n\n<a name=\"Custom-Spot\"></a>\n\n```md\n## Not a heading\n```\n"

    assert CheckLinks.anchors(text) ==
             MapSet.new(
               ~w(title the-mix-lmx-task replacing-a-tools-receipt qa-whats-new title-1 setext-heading custom-spot)
             )

    assert CheckLinks.anchors("## Café &amp; &#x3b1; &copy;\n## `a_b` and **bold**\n") ==
             MapSet.new(["café--α-", "a_b-and-bold"])
  end

  @tag :tmp_dir
  test "checks a clean tree without fetching external URLs or reading fixture repositories", %{
    tmp_dir: root
  } do
    repository(root, @files)
    output = capture_io(fn -> assert CheckLinks.main(["--root", root]) == 0 end)
    assert output =~ "0 broken"
  end

  @tag :tmp_dir
  test "reports paths, anchors and private repositories with source line numbers", %{
    tmp_dir: root
  } do
    private = "https://github.com/" <> "houllette/secret-host"

    files =
      Map.merge(@files, %{
        "docs/broken.md" =>
          "[gone](missing.md) [anchor](guide.md#no-such-part) [self](#nowhere)\n[up](../../outside.md)\n[main](https://github.com/houllette/lemieux/blob/main/docs/absent.md)\n[pinned](https://github.com/houllette/lemieux/tree/0123abc/docs)\n",
        "lib/thing.ex" => "@url \"#{private}/issues\"\n"
      })

    repository(root, files)
    output = capture_io(fn -> assert CheckLinks.main(["--root", root]) == 1 end)
    assert output =~ "docs/broken.md:1: error: missing.md: docs/missing.md does not exist"
    assert output =~ "no heading in docs/guide.md has the anchor #no-such-part"
    assert output =~ "no heading in docs/broken.md has the anchor #nowhere"
    assert output =~ "docs/broken.md:2: error: ../../outside.md: points outside the repository"
    assert output =~ "docs/absent.md does not exist"
    assert output =~ "docs/broken.md:4: warning:"
    assert output =~ "lib/thing.ex:1: error: #{private}"
    refute output =~ "eval/corpus"
    assert output =~ "6 broken, 1 warnings"
  end

  @tag :tmp_dir
  test "names untracked and deleted targets, decodes paths, and checks only selected files", %{
    tmp_dir: root
  } do
    repository(root, Map.put(@files, "docs/space name.md", "# New\n"))
    File.write!(Path.join(root, "docs/new.md"), "# New\n")

    File.write!(
      Path.join(root, "docs/guide.md"),
      "[new](new.md) [encoded](space%20name.md#new)\n[deleted](../assets/pic.png)\n"
    )

    File.rm!(Path.join(root, "assets/pic.png"))

    output =
      capture_io(fn ->
        assert CheckLinks.main(["--root", root, Path.join(root, "docs/guide.md")]) == 1
      end)

    assert output =~ "docs/new.md exists here but is not tracked"
    assert output =~ "assets/pic.png is tracked but deleted"
    refute output =~ "space%20name.md:"
    assert output =~ "1 Markdown files"
  end

  test "ignores code and comments while retaining the line numbers of real links" do
    text = "```md\n[x](bad.md)\n```\n<!-- [x](bad.md) -->\n`[x](bad.md)`\n[real](good.md)\n"
    assert CheckLinks.extract_links(text) == [{6, "good.md"}]

    assert CheckLinks.extract_links("[text\nwrapped](good.md)\n<https://example.com/a>\n") == [
             {1, "good.md"},
             {3, "https://example.com/a"}
           ]
  end

  @tag :tmp_dir
  test "usage errors return without halting the test VM", %{tmp_dir: root} do
    assert capture_io(:stderr, fn -> assert CheckLinks.main(["--unknown"]) == 2 end) =~ "usage:"

    assert capture_io(:stderr, fn ->
             assert CheckLinks.main(["--root", Path.join(root, "absent")]) == 2
           end) =~
             "not a Git checkout"
  end

  defp repository(root, files) do
    for {name, bytes} <- files do
      path = Path.join(root, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, bytes)
    end

    {_, 0} = System.cmd("git", ["-c", "init.templateDir=", "init", "-q", root])
    {_, 0} = System.cmd("git", ["-C", root, "add", "-A"])
  end
end
