defmodule Lemieux.ReferenceTest do
  use ExUnit.Case, async: true

  alias Lemieux.Environment
  alias Lemieux.Reference

  doctest Lemieux.Reference

  defp paths(text), do: text |> Reference.parse() |> Enum.map(& &1.path)

  defp expand(text, cwd, opts \\ []),
    do: text |> Reference.parse() |> Reference.resolve(Environment.local(), cwd, opts)

  describe "parse/1" do
    test "finds a reference at the start of the text" do
      assert [%Reference{raw: "@lib/lemieux/turn.ex", path: "lib/lemieux/turn.ex"}] =
               Reference.parse("@lib/lemieux/turn.ex explain this")
    end

    test "finds several references in the order they were typed" do
      assert paths("compare @lib/a.ex with @lib/b.ex please") == ["lib/a.ex", "lib/b.ex"]
    end

    test "returns nothing for text without references" do
      assert Reference.parse("just a normal sentence") == []
      assert Reference.parse("") == []
    end

    test "keeps the first spelling when the same path is referenced twice" do
      assert [%Reference{raw: "@lib/a.ex"}] = Reference.parse(~s(@lib/a.ex then @"lib/a.ex"))
    end

    test "ignores an email address, which is an @ nobody meant as a path" do
      assert Reference.parse("mail someone@example.com about it") == []
    end

    test "ignores a reference escaped with a backslash" do
      assert Reference.parse(~S(leave \@lib/a.ex alone)) == []
    end

    test "ignores a bare @ and a doubled @" do
      assert Reference.parse("what @ even is @@ this") == []
    end
  end

  describe "parse/1 boundaries" do
    test "matches after an opening bracket or quote" do
      assert paths("see (@lib/a.ex) and [@lib/b.ex]") == ["lib/a.ex", "lib/b.ex"]
    end

    test "matches on a later line" do
      assert paths("first line\n@lib/a.ex") == ["lib/a.ex"]
    end

    test "stops at punctuation that cannot be in a path" do
      assert paths("read @lib/a.ex, then @lib/b.ex? yes") == ["lib/a.ex", "lib/b.ex"]
    end

    test "strips a trailing full stop, which ends a sentence far more often than a filename" do
      assert paths("read @lib/a.ex.") == ["lib/a.ex"]
    end

    test "keeps a trailing slash, which is how a directory says it is one" do
      assert paths("list @lib/lemieux/") == ["lib/lemieux/"]
    end
  end

  describe "parse/1 quoting" do
    test "a quoted reference may contain spaces" do
      assert [%Reference{path: "src/my file.ex", quoted?: true}] =
               Reference.parse(~s(open @"src/my file.ex" now))
    end

    test "a quoted reference is not punctuation-stripped" do
      assert paths(~s(@"weird name.")) == ["weird name."]
    end

    test "an unterminated quote is not a reference" do
      assert Reference.parse(~s(@"never closed)) == []
    end
  end

  describe "parse/1 explicitness" do
    test "a path with a separator is explicit" do
      assert [%Reference{explicit?: true}] = Reference.parse("@lib/thing")
    end

    test "a named extension is explicit" do
      assert [%Reference{explicit?: true}] = Reference.parse("@README.md")
    end

    test "a quoted reference is explicit even when it is a bare word" do
      assert [%Reference{explicit?: true}] = Reference.parse(~s(@"Makefile"))
    end

    test "a bare word is not explicit, so pasted module attributes stay quiet" do
      for attribute <- ~w(@spec @moduledoc @impl @behaviour @enforce_keys) do
        assert [%Reference{explicit?: false}] = Reference.parse(attribute)
      end
    end

    test "a version-shaped dotted word is not explicit" do
      # `.3` is not an extension anybody names a file with, and "bump to
      # @1.2.3" must not report a missing file.
      assert [%Reference{explicit?: false}] = Reference.parse("bump to @1.2.3")
    end
  end

  describe "parse/1 lexing" do
    test "an absolute path parses, because rejecting it is the environment's job" do
      assert paths("@/etc/passwd") == ["/etc/passwd"]
    end

    test "a parent-directory path parses, for the same reason" do
      assert paths("@../secrets.txt") == ["../secrets.txt"]
    end

    test "glob characters survive lexing" do
      assert paths("@lib/**/*.ex") == ["lib/**/*.ex"]
    end

    test "dashes, underscores and tildes are ordinary path characters" do
      assert paths("@lib/my-file_name~1.ex") == ["lib/my-file_name~1.ex"]
    end
  end

  describe "resolve/4" do
    @describetag :tmp_dir

    test "reads a file and numbers it the way the read tool does", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "a.ex"), "defmodule A do\nend\n")

      assert [attachment] = expand("explain @a.ex", cwd)

      assert attachment == %{
               "ref" => "@a.ex",
               "path" => "a.ex",
               "kind" => "file",
               "bytes" => byte_size(attachment["text"]),
               "text" => """
               <attachment path="a.ex">
               1\tdefmodule A do
               2\tend
               </attachment>\
               """
             }
    end

    test "resolves several references in the order they were typed", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "a.ex"), "a")
      File.write!(Path.join(cwd, "b.ex"), "b")

      assert ["a.ex", "b.ex"] =
               "@a.ex and @b.ex" |> expand(cwd) |> Enum.map(& &1["path"])
    end

    test "reports an explicit reference that names no file", %{tmp_dir: cwd} do
      assert [%{"kind" => "error", "path" => "lib/typo.ex"} = attachment] =
               expand("read @lib/typo.ex", cwd)

      assert attachment["text"] == ~s(<attachment path="lib/typo.ex" error="no such file" />)
    end

    test "says nothing about an ambiguous reference that names no file", %{tmp_dir: cwd} do
      # `@spec` in a pasted snippet is not a missing file, it is Elixir.
      assert expand("look at @spec and @moduledoc", cwd) == []
    end

    test "resolves an ambiguous reference that does name a file", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "Makefile"), "all:\n")

      assert [%{"kind" => "file", "path" => "Makefile"}] = expand("read @Makefile", cwd)
    end

    test "never expands an ambiguous reference to a directory", %{tmp_dir: cwd} do
      # The reason the explicit/ambiguous split exists: a pasted `@test` must
      # not attach a whole tree.
      File.mkdir_p!(Path.join(cwd, "test"))

      assert expand("as in @test above", cwd) == []
    end

    test "lists an explicit directory", %{tmp_dir: cwd} do
      File.mkdir_p!(Path.join([cwd, "lib", "nested"]))
      File.write!(Path.join([cwd, "lib", "a.ex"]), "")

      assert [%{"kind" => "directory", "path" => "lib/", "text" => text}] =
               expand("read @lib/", cwd)

      assert text == """
             <attachment path="lib/" kind="directory">
             1\ta.ex
             2\tnested/
             </attachment>\
             """
    end

    test "says so rather than nothing when an explicit directory is empty", %{tmp_dir: cwd} do
      File.mkdir_p!(Path.join(cwd, "empty"))

      assert [%{"kind" => "directory", "text" => text}] = expand("read @empty/", cwd)
      assert text =~ ~s(note="is an empty directory")
    end

    test "windows a directory with more entries than are worth sending", %{tmp_dir: cwd} do
      File.mkdir_p!(Path.join(cwd, "many"))

      for index <- 1..12,
          do: File.write!(Path.join([cwd, "many", "f#{index}.ex"]), "")

      assert [%{"text" => text}] = expand("read @many/", cwd, max_entries: 5)

      assert text =~ "[showing 5 of 12 entries]"
      refute text =~ "f9.ex"
    end

    test "reports a reference that escapes the working directory", %{tmp_dir: cwd} do
      assert [%{"kind" => "error", "text" => text}] = expand("read @../secrets.txt", cwd)
      assert text =~ ~s(error="is outside the working directory")
    end

    test "keeps the first spelling but resolves the path once", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "a.ex"), "a")

      assert [%{"ref" => "@a.ex"}] = expand(~s(@a.ex twice @"a.ex"), cwd)
    end

    test "truncates a file that is too large, and says where", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "big.txt"), String.duplicate("x", 5_000))

      assert [%{"text" => text}] = expand("read @big.txt", cwd, max_bytes: 400)

      assert text =~ "bytes cut from the middle by lemieux"
      assert byte_size(text) < 1_000
    end

    test "stops attaching once the prompt's byte budget is spent", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "a.ex"), String.duplicate("a", 500))
      File.write!(Path.join(cwd, "b.ex"), String.duplicate("b", 500))

      assert [%{"path" => "a.ex", "kind" => "file"}, %{"path" => "b.ex"} = second] =
               expand("@a.ex and @b.ex", cwd, budget: 300)

      assert second["kind"] == "error"
      assert second["text"] =~ "budget"
    end

    test "an ambiguous reference is dropped rather than reported when the budget is spent",
         %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "a.ex"), String.duplicate("a", 500))
      File.write!(Path.join(cwd, "Makefile"), "all:\n")

      assert [%{"path" => "a.ex"}] = expand("@a.ex and @Makefile", cwd, budget: 300)
    end

    test "replaces bytes that are not valid UTF-8, which a transcript cannot hold",
         %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "odd.txt"), <<0xFF, 0xFE, "ok">>)

      assert [%{"text" => text}] = expand("read @odd.txt", cwd)
      assert String.valid?(text)
    end

    test "reports an empty file as empty rather than as nothing", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "empty.txt"), "")

      assert [%{"kind" => "file", "text" => text}] = expand("read @empty.txt", cwd)
      assert text =~ "is empty (0 bytes)"
    end

    test "carries an image as bytes rather than as mangled text", %{tmp_dir: cwd} do
      png = <<0x89, "PNG\r\n", 0x1A, 0x0A, 0, 1, 2, 3>>
      File.write!(Path.join(cwd, "shot.png"), png)

      assert [attachment] = expand("what is in @shot.png", cwd)

      assert attachment["kind"] == "image"
      assert attachment["media_type"] == "image/png"
      assert Base.decode64!(attachment["data"]) == png
      refute Map.has_key?(attachment, "text")
    end

    test "recognises the image types every provider accepts", %{tmp_dir: cwd} do
      for {name, media_type} <- [
            {"a.png", "image/png"},
            {"b.jpg", "image/jpeg"},
            {"c.jpeg", "image/jpeg"},
            {"d.gif", "image/gif"},
            {"e.webp", "image/webp"}
          ] do
        File.write!(Path.join(cwd, name), "bytes")

        assert [%{"media_type" => ^media_type, "kind" => "image"}] = expand("@#{name}", cwd)
      end
    end

    test "a PDF is a document rather than an image", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "paper.pdf"), "%PDF-1.7")

      assert [%{"kind" => "document", "media_type" => "application/pdf"}] =
               expand("read @paper.pdf", cwd)
    end

    test "refuses an image too large to send, rather than sending it", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "huge.png"), String.duplicate("x", 2_000))

      assert [%{"kind" => "error", "text" => text}] =
               expand("@huge.png", cwd, max_image_bytes: 1_000)

      assert text =~ "too large"
    end

    test "caps how many files with their own bytes ride on one prompt", %{tmp_dir: cwd} do
      for name <- ~w(a.png b.png c.png), do: File.write!(Path.join(cwd, name), "bytes")

      assert [%{"kind" => "image"}, %{"kind" => "image"}, %{"kind" => "error"} = third] =
               expand("@a.png @b.png @c.png", cwd, max_images: 2)

      assert third["text"] =~ "no more than 2"
    end

    test "an image does not spend the budget the text attachments share", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "shot.png"), String.duplicate("x", 900))
      File.write!(Path.join(cwd, "a.ex"), "hello")

      assert [%{"kind" => "image"}, %{"kind" => "file"}] =
               expand("@shot.png then @a.ex", cwd, budget: 400)
    end

    test "expands a glob into one attachment per file it matched", %{tmp_dir: cwd} do
      File.mkdir_p!(Path.join(cwd, "lib"))
      File.write!(Path.join([cwd, "lib", "a.ex"]), "a")
      File.write!(Path.join([cwd, "lib", "b.ex"]), "b")
      File.write!(Path.join([cwd, "lib", "c.txt"]), "c")

      assert ["lib/a.ex", "lib/b.ex"] =
               "read @lib/*.ex" |> expand(cwd) |> Enum.map(& &1["path"])
    end

    test "keeps the glob as the reference each match came from", %{tmp_dir: cwd} do
      File.mkdir_p!(Path.join(cwd, "lib"))
      File.write!(Path.join([cwd, "lib", "a.ex"]), "a")

      assert [%{"ref" => "@lib/*.ex", "path" => "lib/a.ex"}] = expand("@lib/*.ex", cwd)
    end

    test "a double star crosses directories", %{tmp_dir: cwd} do
      File.mkdir_p!(Path.join([cwd, "lib", "deep", "deeper"]))
      File.write!(Path.join([cwd, "lib", "top.ex"]), "")
      File.write!(Path.join([cwd, "lib", "deep", "middle.ex"]), "")
      File.write!(Path.join([cwd, "lib", "deep", "deeper", "bottom.ex"]), "")

      assert ["lib/deep/deeper/bottom.ex", "lib/deep/middle.ex", "lib/top.ex"] =
               "@lib/**/*.ex" |> expand(cwd) |> Enum.map(& &1["path"])
    end

    test "a bare double star means every file under it", %{tmp_dir: cwd} do
      File.mkdir_p!(Path.join([cwd, "lib", "deep"]))
      File.write!(Path.join([cwd, "lib", "a.ex"]), "")
      File.write!(Path.join([cwd, "lib", "deep", "b.ex"]), "")

      assert ["lib/a.ex", "lib/deep/b.ex"] =
               "@lib/**" |> expand(cwd) |> Enum.map(& &1["path"])
    end

    test "matches a directory name as well as a file name", %{tmp_dir: cwd} do
      File.mkdir_p!(Path.join([cwd, "apps", "one"]))
      File.mkdir_p!(Path.join([cwd, "apps", "two"]))
      File.write!(Path.join([cwd, "apps", "one", "mix.exs"]), "one")
      File.write!(Path.join([cwd, "apps", "two", "mix.exs"]), "two")

      assert ["apps/one/mix.exs", "apps/two/mix.exs"] =
               "@apps/*/mix.exs" |> expand(cwd) |> Enum.map(& &1["path"])
    end

    test "says so when a glob matched nothing", %{tmp_dir: cwd} do
      assert [%{"kind" => "error", "text" => text}] = expand("@lib/*.nope", cwd)
      assert text =~ "matched no files"
    end

    test "says how many it left behind rather than capping in silence", %{tmp_dir: cwd} do
      File.mkdir_p!(Path.join(cwd, "lib"))

      for index <- 1..9,
          do: File.write!(Path.join([cwd, "lib", "f#{index}.ex"]), "")

      attachments = expand("@lib/*.ex", cwd, max_glob_matches: 3)

      assert length(attachments) == 4
      assert List.last(attachments)["text"] =~ "matched 9 files"
    end

    test "does not follow a symlinked directory, which is how a walk loops forever",
         %{tmp_dir: cwd} do
      File.mkdir_p!(Path.join(cwd, "lib"))
      File.write!(Path.join([cwd, "lib", "a.ex"]), "")
      File.ln_s!(Path.join(cwd, "lib"), Path.join([cwd, "lib", "loop"]))

      assert ["lib/a.ex"] = "@lib/**/*.ex" |> expand(cwd) |> Enum.map(& &1["path"])
    end

    test "an ambiguous glob is not a glob", %{tmp_dir: cwd} do
      File.write!(Path.join(cwd, "anything"), "")

      assert expand("multiply by @* please", cwd) == []
    end

    test "resolves nothing when there is nothing to resolve", %{tmp_dir: cwd} do
      assert Reference.resolve([], Environment.local(), cwd) == []
    end
  end

  describe "parse/1 MCP resources" do
    test "reads @server:uri as a resource of that server" do
      assert [
               %Reference{
                 raw: "@docs:file:///guide.md",
                 path: "docs:file:///guide.md",
                 kind: :resource,
                 server: "docs",
                 uri: "file:///guide.md",
                 explicit?: true
               }
             ] = Reference.parse("summarise @docs:file:///guide.md for me")
    end

    test "leaves sentence punctuation and an unopened bracket to the sentence" do
      assert [%Reference{uri: "mem://notes"}] = Reference.parse("read @docs:mem://notes.")
      assert [%Reference{uri: "mem://notes"}] = Reference.parse("(see @docs:mem://notes)")
      assert [%Reference{uri: "mem://f(x)"}] = Reference.parse("see @docs:mem://f(x)")
    end

    test "a colon that does not start a URI leaves the old reading alone" do
      assert [%Reference{kind: :path, path: "README.md", explicit?: true}] =
               Reference.parse("@README.md: it says so")

      assert [%Reference{kind: :path, path: "10", explicit?: false}] =
               Reference.parse("meet @10:30:00")

      assert [%Reference{kind: :path, path: "name", explicit?: false}] =
               Reference.parse("@name:x:.")
    end

    test "a path with a colon in it is quoted, as any unusual path is" do
      assert [%Reference{kind: :path, path: "notes:v2.md", quoted?: true}] =
               Reference.parse(~s(read @"notes:v2.md"))
    end

    test "an address is still not a reference" do
      assert Reference.parse("write to someone@example.com:mailto:x") == []
    end

    test "the same resource named twice is one reference" do
      assert [%Reference{uri: "mem://a"}] =
               Reference.parse("@docs:mem://a and again @docs:mem://a")
    end
  end

  describe "resolve/4 MCP resources" do
    defp resolve_resources(text, opts),
      do:
        text
        |> Reference.parse()
        |> Reference.resolve(Environment.local(), System.tmp_dir!(), opts)

    test "attaches what the server returned, numbered like a file" do
      reader = fn "docs", "mem://notes" -> {:ok, "remember the milk\nand eggs"} end

      assert [attachment] = resolve_resources("use @docs:mem://notes", resource: reader)

      assert %{
               "ref" => "@docs:mem://notes",
               "path" => "docs:mem://notes",
               "kind" => "resource",
               "server" => "docs",
               "uri" => "mem://notes"
             } = attachment

      assert attachment["text"] =~ ~s(<attachment path="docs:mem://notes" kind="resource">)
      assert attachment["text"] =~ "1\tremember the milk"
      assert attachment["text"] =~ "2\tand eggs"
      assert attachment["bytes"] == byte_size(attachment["text"])
    end

    test "says so when no connected server has that name" do
      reader = fn _server, _uri -> {:error, :unknown_server} end

      assert [%{"kind" => "error", "text" => text, "server" => "docs"}] =
               resolve_resources("use @docs:mem://notes", resource: reader)

      assert text =~ "no connected MCP server is called docs"
    end

    test "says so when nothing here can read resources" do
      assert [%{"kind" => "error", "text" => text}] =
               resolve_resources("use @docs:mem://notes", [])

      assert text =~ "MCP resources cannot be read here"
    end

    test "keeps a server's error text from ending the attribute it lands in" do
      reader = fn _server, _uri -> {:error, ~s(no "notes"\nhere)} end

      assert [%{"text" => text}] = resolve_resources("use @docs:mem://notes", resource: reader)
      assert text =~ ~s(error="no 'notes' here")
    end

    test "spends the byte budget files spend" do
      reader = fn _server, uri -> {:ok, String.duplicate("x", 500) <> uri} end

      assert [first, second] =
               resolve_resources("@docs:mem://a @docs:mem://b", resource: reader, budget: 200)

      assert first["kind"] == "resource"
      assert first["bytes"] <= 400
      assert second["kind"] == "error"
      assert second["text"] =~ "budget was already spent"
    end

    test "a stored resource attachment is read again as the same resource" do
      reader = fn "docs", "mem://notes" -> {:ok, "hello"} end
      [attachment] = resolve_resources("@docs:mem://notes", resource: reader)

      assert %Reference{kind: :resource, server: "docs", uri: "mem://notes"} =
               Reference.from_attachment(attachment)

      assert %Reference{kind: :path, path: "a.ex", explicit?: true} =
               Reference.from_attachment(%{"ref" => "@a.ex", "path" => "a.ex", "kind" => "file"})
    end
  end
end
