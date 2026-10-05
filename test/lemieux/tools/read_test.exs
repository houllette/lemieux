defmodule Lemieux.Tools.ReadTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tools.Read

  defmodule FilesOnlyEnvironment do
    def read_file(_state, _cwd, _path), do: {:error, :eisdir}
  end

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{
      ctx: %{
        cwd: tmp_dir,
        session_id: "s1",
        call_id: "c1",
        environment: Lemieux.Environment.local()
      }
    }
  end

  defp write(tmp_dir, name, contents) do
    path = Path.join(tmp_dir, name)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    name
  end

  test "returns file contents with line numbers", %{tmp_dir: tmp_dir, ctx: ctx} do
    file = write(tmp_dir, "a.txt", "one\ntwo\nthree\n")

    assert {:ok, output} = Read.run(%{"path" => file}, ctx)

    assert output == """
           1\tone
           2\ttwo
           3\tthree\
           """
  end

  test "offset and limit window the file", %{tmp_dir: tmp_dir, ctx: ctx} do
    file = write(tmp_dir, "a.txt", Enum.map_join(1..10, "\n", &"line #{&1}"))

    assert {:ok, output} = Read.run(%{"path" => file, "offset" => 3, "limit" => 2}, ctx)

    # Numbering follows the file, not the window: a model that reads lines 3-4
    # and is shown them as 1-2 will edit the wrong place. And a window says it
    # is one, so the model knows there is more of the file it has not seen.
    assert output == "3\tline 3\n4\tline 4\n\n[showing lines 3-4 of 10]"
  end

  test "an offset past the end says so rather than returning nothing", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    file = write(tmp_dir, "a.txt", "one\ntwo\n")

    assert {:ok, output} = Read.run(%{"path" => file, "offset" => 99}, ctx)
    assert output =~ "2 lines"
  end

  test "a missing file is an error, not a crash", %{ctx: ctx} do
    assert {:error, message} = Read.run(%{"path" => "nope.txt"}, ctx)
    assert message =~ "nope.txt"
    assert message =~ "no such file"
  end

  test "a directory lists one sorted level with type markers", %{tmp_dir: tmp_dir, ctx: ctx} do
    File.mkdir_p!(Path.join(tmp_dir, "sub/nested"))
    File.write!(Path.join(tmp_dir, "sub/b.txt"), "b")
    File.write!(Path.join(tmp_dir, "sub/a.txt"), "a")
    File.ln_s!("a.txt", Path.join(tmp_dir, "sub/current"))

    assert {:ok, listing} = Read.run(%{"path" => "sub"}, ctx)

    assert listing == "1\ta.txt\n2\tb.txt\n3\tcurrent@\n4\tnested/"
  end

  test "offset and limit window a directory listing", %{tmp_dir: tmp_dir, ctx: ctx} do
    File.mkdir_p!(Path.join(tmp_dir, "sub"))
    Enum.each(~w(a b c d), &File.write!(Path.join(tmp_dir, "sub/#{&1}"), &1))

    assert {:ok, listing} =
             Read.run(%{"path" => "sub", "offset" => 2, "limit" => 2}, ctx)

    assert listing == "2\tb\n3\tc\n\n[showing lines 2-3 of 4]"
  end

  test "a files-only host environment gets an actionable directory error", %{ctx: ctx} do
    ctx = Map.put(ctx, :environment, FilesOnlyEnvironment)

    assert {:error, message} = Read.run(%{"path" => "sub"}, ctx)
    assert message == "sub: directory listing is not supported here"
  end

  test "an empty file reports emptiness rather than looking like a failure", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    file = write(tmp_dir, "empty.txt", "")

    assert {:ok, output} = Read.run(%{"path" => file}, ctx)
    assert output =~ "empty"
  end

  test "output beyond the size cap stops at a line and says where to continue", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    # Long lines rather than many lines, so the byte cap is what bites rather
    # than the line limit — they are different caps doing different jobs.
    file =
      write(tmp_dir, "big.txt", Enum.map_join(1..200, "\n", &String.duplicate("#{&1} ", 500)))

    assert {:ok, output} = Read.run(%{"path" => file}, ctx)
    assert byte_size(output) < 62_000

    [_all, next] = Regex.run(~r/continue with offset=(\d+); the file has 200 lines/, output)
    next = String.to_integer(next)
    shown = output |> String.split("\n") |> Enum.filter(&String.contains?(&1, "\t"))

    # Every line up to the cut is shown whole, in order, and nothing after it:
    # the continuation picks up exactly where this stopped.
    assert length(shown) == next - 1
    assert List.last(shown) == "#{next - 1}\t" <> String.duplicate("#{next - 1} ", 500)

    assert {:ok, rest} = Read.run(%{"path" => file, "offset" => next}, ctx)
    assert rest =~ ~r/\A#{next}\t/
  end

  test "a very long line is shown up to the cap and marked", %{tmp_dir: tmp_dir, ctx: ctx} do
    file = write(tmp_dir, "min.js", "short\n" <> String.duplicate("x", 50_000) <> "\nafter\n")

    assert {:ok, output} = Read.run(%{"path" => file}, ctx)

    assert output =~
             "1\tshort\n2\t" <> String.duplicate("x", 2_000) <> " … [a 50000-byte line, cut"

    assert output =~ "3\tafter"
  end

  test "a binary file is reported, not decoded", %{tmp_dir: tmp_dir, ctx: ctx} do
    file =
      write(tmp_dir, "image.png", <<137, 80, 78, 71, 0, 0, 0, 13>> <> String.duplicate("z", 100))

    assert {:ok, output} = Read.run(%{"path" => file}, ctx)
    assert output =~ "is a binary file"
    refute output =~ "zzz"
  end

  test "a NUL byte after the first 8 KB does not make a text file binary", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    file = write(tmp_dir, "late.txt", String.duplicate("a", 9_000) <> <<0>> <> "\nend\n")

    assert {:ok, output} = Read.run(%{"path" => file}, ctx)
    assert output =~ "2\tend"
  end

  test "carriage returns are not shown, and the output says the file has them", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    file = write(tmp_dir, "win.txt", "one\r\ntwo\r\n")

    assert {:ok, output} = Read.run(%{"path" => file}, ctx)
    assert output =~ "1\tone\n2\ttwo"
    refute output =~ "\r"
    assert output =~ "CRLF"
  end

  test "a file larger than one chunk is counted and windowed correctly", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    file = write(tmp_dir, "many.txt", Enum.map_join(1..50_000, "\n", &"line #{&1}") <> "\n")

    assert {:ok, output} =
             Read.run(%{"path" => file, "offset" => 30_000, "limit" => 2}, ctx)

    assert output ==
             "30000\tline 30000\n30001\tline 30001\n\n[showing lines 30000-30001 of 50000]"
  end

  test "a relative path is resolved against the session's cwd, not the VM's", %{
    tmp_dir: tmp_dir,
    ctx: ctx
  } do
    write(tmp_dir, "nested/deep.txt", "found me")

    assert {:ok, output} = Read.run(%{"path" => "nested/deep.txt"}, ctx)
    assert output =~ "found me"
  end

  test "an absolute path is accepted when it points inside", %{tmp_dir: tmp_dir, ctx: ctx} do
    write(tmp_dir, "abs.txt", "absolutely")

    assert {:ok, output} = Read.run(%{"path" => Path.join(tmp_dir, "abs.txt")}, ctx)
    assert output == "1\tabsolutely"
  end

  test "an absolute path outside the working directory is refused", %{ctx: ctx} do
    assert {:error, output} = Read.run(%{"path" => "/etc/hosts"}, ctx)
    assert output =~ "outside"
  end

  test "a symlink cannot escape the working directory", %{tmp_dir: tmp_dir, ctx: ctx} do
    outside = Path.join(Path.dirname(tmp_dir), "outside-#{System.unique_integer([:positive])}")
    File.write!(outside, "secret")
    File.ln_s!(outside, Path.join(tmp_dir, "escape"))

    assert {:error, output} = Read.run(%{"path" => "escape"}, ctx)
    assert output =~ "outside"
  end

  test "invalid bytes do not stop the read", %{tmp_dir: tmp_dir, ctx: ctx} do
    file = write(tmp_dir, "binary.bin", <<0xFF, 0xFE, ?h, ?i>>)

    assert {:ok, output} = Read.run(%{"path" => file}, ctx)
    assert String.valid?(output)
  end

  test "the tool describes itself well enough to be called" do
    assert Read.name() == "read"
    assert Read.description() =~ "directory"
    assert %{"properties" => %{"path" => _}, "required" => ["path"]} = Read.schema()
  end

  describe "images and PDFs" do
    alias Lemieux.Tool.Result

    @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 64::32, 48::32, 8, 6, 0, 0,
           0>>
    @pdf "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n"

    # Files are this environment's local ones; commands answer as `pdftotext`
    # would, so the fallback is tested without the program installed.
    defmodule PdfToText do
      alias Lemieux.Environment.Local

      def read_file(_state, cwd, path), do: Local.read_file(nil, cwd, path)
      def stream_file(_state, cwd, path), do: Local.stream_file(nil, cwd, path)
      def write_file(_state, cwd, path, contents), do: Local.write_file(nil, cwd, path, contents)

      def run(%{test: test, output: output, status: status}, command, _opts) do
        send(test, {:ran, command})
        {:ok, [{:data, output}, {:exit_status, status}]}
      end
    end

    test "an image is attached for a model that can view images", %{
      tmp_dir: tmp_dir,
      ctx: ctx
    } do
      file = write(tmp_dir, "shots/screen.png", @png)
      ctx = Map.put(ctx, :input_modalities, [:text, :image])

      assert {:ok, %Result{model_text: text, attachments: [attachment]}} =
               Read.run(%{"path" => file}, ctx)

      assert text ==
               "shots/screen.png: image (image/png, #{byte_size(@png)} B, 64×48), " <>
                 "attached for you to view."

      assert attachment["kind"] == "image"
      assert attachment["media_type"] == "image/png"
      assert Base.decode64!(attachment["data"]) == @png
    end

    # An image a model cannot read is a refusal of every later request that
    # still carries it, and "we do not know" is not "yes".
    test "an image is described, not attached, for a text-only or unknown model", %{
      tmp_dir: tmp_dir,
      ctx: ctx
    } do
      file = write(tmp_dir, "screen.png", @png)

      assert {:ok, text_only} =
               Read.run(%{"path" => file}, Map.put(ctx, :input_modalities, [:text]))

      assert text_only =~ "screen.png is an image (image/png"
      assert text_only =~ "the current model cannot view images"

      assert {:ok, unknown} = Read.run(%{"path" => file}, ctx)
      assert unknown =~ "does not know whether its model can view images"
    end

    test "the bytes decide: a .png that is text is read as text", %{tmp_dir: tmp_dir, ctx: ctx} do
      file = write(tmp_dir, "notes.png", "not really\nan image\n")
      ctx = Map.put(ctx, :input_modalities, [:text, :image])

      assert {:ok, "1\tnot really\n2\tan image"} = Read.run(%{"path" => file}, ctx)
    end

    test "an image over the attachment limit is described instead", %{
      tmp_dir: tmp_dir,
      ctx: ctx
    } do
      file = write(tmp_dir, "huge.png", @png <> :binary.copy(<<0>>, 3_600_000))
      ctx = Map.put(ctx, :input_modalities, [:text, :image])

      assert {:ok, text} = Read.run(%{"path" => file}, ctx)
      assert text =~ "huge.png is an image (over 3.5 MB)"
      assert text =~ "images over 3.5 MB are too large to attach"
    end

    test "a PDF is attached for a model that reads PDFs", %{tmp_dir: tmp_dir, ctx: ctx} do
      file = write(tmp_dir, "paper.pdf", @pdf)
      ctx = Map.put(ctx, :input_modalities, [:text, :image, :pdf])

      assert {:ok, %Result{attachments: [attachment], model_text: text}} =
               Read.run(%{"path" => file}, ctx)

      assert attachment["kind"] == "document"
      assert attachment["path"] == "paper.pdf"
      assert text =~ "paper.pdf: PDF document (application/pdf"
    end

    test "a PDF a model cannot read is converted with pdftotext, through the environment", %{
      tmp_dir: tmp_dir,
      ctx: ctx
    } do
      file = write(tmp_dir, "paper.pdf", @pdf)

      environment =
        {PdfToText, %{test: self(), output: "Title\n\nFirst paragraph.\n", status: 0}}

      ctx = %{ctx | environment: environment} |> Map.put(:input_modalities, [:text, :image])

      assert {:ok, text} = Read.run(%{"path" => file}, ctx)
      assert_received {:ran, "'pdftotext' '-layout' '-q' '-enc' 'UTF-8' 'paper.pdf' '-'"}

      assert text ==
               "[text extracted from paper.pdf with pdftotext; the PDF itself is not attached " <>
                 "because the current model cannot read PDFs]\n\n" <>
                 "1\tTitle\n2\t\n3\tFirst paragraph."
    end

    test "without pdftotext a PDF is described and bash is suggested", %{
      tmp_dir: tmp_dir,
      ctx: ctx
    } do
      file = write(tmp_dir, "paper.pdf", @pdf)

      environment =
        {PdfToText, %{test: self(), output: "sh: pdftotext: not found\n", status: 127}}

      assert {:ok, text} = Read.run(%{"path" => file}, %{ctx | environment: environment})
      assert text =~ "paper.pdf is a PDF (application/pdf"
      assert text =~ "does not know whether its model can read PDFs"
      assert text =~ "pdftotext is not available here"
    end
  end
end
