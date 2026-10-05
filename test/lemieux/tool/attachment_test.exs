defmodule Lemieux.Tool.AttachmentTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tool.Attachment

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 800::32, 600::32, 8, 6, 0, 0,
         0>>

  @gif "GIF89a" <> <<320::little-16, 200::little-16>> <> <<0, 0, 0>>

  # An APP0 segment the walker has to step over before the frame header.
  @jpeg <<0xFF, 0xD8, 0xFF, 0xE0, 0, 16, "JFIF", 0, 1, 1, 0, 0, 1, 0, 1, 0, 0, 0xFF, 0xC0, 0, 17,
          8, 480::16, 640::16, 3>>

  @webp "RIFF" <>
          <<30::little-32>> <>
          "WEBP" <>
          "VP8X" <> <<10::little-32>> <> <<0::32>> <> <<1023::little-24, 767::little-24>>

  @pdf "%PDF-1.7\n%âãÏÓ\n1 0 obj\n"

  test "new/4 builds the same shape a prompt's @ attachment has" do
    attachment = Attachment.new(:image, "image/png", @png, path: "shot.png")
    data = Base.encode64(@png)

    assert attachment == %{
             "kind" => "image",
             "media_type" => "image/png",
             "data" => data,
             "bytes" => byte_size(data),
             "size" => byte_size(@png),
             "path" => "shot.png"
           }

    assert Attachment.valid?(attachment)
    refute Attachment.valid?(%{"kind" => "audio", "media_type" => "audio/wav", "data" => ""})
    refute Attachment.valid?(%{kind: "image", media_type: "image/png", data: ""})
  end

  test "an extension is a claim and the magic number is the answer" do
    assert Attachment.kind_of("a/Shot.PNG") == {:image, "image/png"}
    assert Attachment.kind_of("report.pdf") == {:document, "application/pdf"}
    assert Attachment.kind_of("notes.txt") == nil

    assert Attachment.sniff(@png) == "image/png"
    assert Attachment.sniff(@jpeg) == "image/jpeg"
    assert Attachment.sniff(@gif) == "image/gif"
    assert Attachment.sniff(@webp) == "image/webp"
    assert Attachment.sniff(@pdf) == "application/pdf"
    assert Attachment.sniff("just text, named .png") == nil
  end

  test "dimensions come from each format's header" do
    assert Attachment.dimensions(@png, "image/png") == {800, 600}
    assert Attachment.dimensions(@gif, "image/gif") == {320, 200}
    assert Attachment.dimensions(@jpeg, "image/jpeg") == {640, 480}
    assert Attachment.dimensions(@webp, "image/webp") == {1024, 768}

    # A truncated header or the wrong type is no answer, never a crash.
    assert Attachment.dimensions(binary_part(@jpeg, 0, 10), "image/jpeg") == nil
    assert Attachment.dimensions(@png, "image/gif") == nil
  end

  test "describe/1 says what a person needs: type, size and dimensions" do
    assert Attachment.describe(Attachment.new(:image, "image/png", @png)) ==
             "image/png, #{byte_size(@png)} B, 800×600"

    assert Attachment.describe(Attachment.new(:document, "application/pdf", @pdf)) ==
             "application/pdf, #{byte_size(@pdf)} B"
  end

  test "an attachment is accepted only by a model known to read its kind" do
    image = Attachment.new(:image, "image/png", @png)
    document = Attachment.new(:document, "application/pdf", @pdf)

    assert Attachment.accepted?(image, [:text, :image])
    refute Attachment.accepted?(image, [:text])
    refute Attachment.accepted?(image, :unknown)

    assert Attachment.accepted?(document, [:text, :image, :pdf])
    refute Attachment.accepted?(document, [:text, :image])
  end

  test "limit/1 keeps at most five, none over its cap, and names the rest" do
    image = Attachment.new(:image, "image/png", @png, path: "ok.png")
    huge = %{Attachment.new(:image, "image/png", @png, path: "huge.png") | "size" => 4_000_000}
    images = [huge | List.duplicate(image, 6)]

    assert {kept, notes} = Attachment.limit(images)
    assert length(kept) == Attachment.max_count()
    assert Enum.all?(kept, &(&1["path"] == "ok.png"))

    assert [oversize, count] = notes
    assert oversize =~ "image huge.png is 4.0 MB, over the 3.5 MB limit"
    assert count =~ "at most 5 attachments"

    assert Attachment.limit([image]) == {[image], []}
  end

  test "size/1 is recovered from the base64 of an attachment written without one" do
    for bytes <- ["a", "ab", "abc", "abcd", @png] do
      attachment = bytes |> then(&Attachment.new(:image, "image/png", &1)) |> Map.delete("size")
      assert Attachment.size(attachment) == byte_size(bytes)
    end
  end
end
