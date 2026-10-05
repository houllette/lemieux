defmodule Lemieux.MCP.AttachmentsTest do
  use ExUnit.Case, async: true

  alias Lemieux.MCP.Protocol
  alias Lemieux.Tool.Result

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 2::32, 3::32, 8, 6, 0, 0, 0>>
  @pdf "%PDF-1.7\n%%EOF\n"

  # The whole path a server's answer takes: `Protocol.output/1` as the client
  # reads it. `MCP.call_tool/3` hands that result on untouched.
  defp through_mcp(result) do
    {:ok, %Result{} = read} = Protocol.output(result)
    read
  end

  test "an image block becomes an attachment, and the text says what it is" do
    result =
      through_mcp(%{
        "content" => [
          %{"type" => "text", "text" => "took a screenshot"},
          %{"type" => "image", "data" => Base.encode64(@png), "mimeType" => "image/png"}
        ]
      })

    assert [attachment] = result.attachments
    assert attachment["kind"] == "image"
    assert Base.decode64!(attachment["data"]) == @png

    assert result.model_text ==
             "took a screenshot\n[image: image/png, #{byte_size(@png)} B, 2×3]"

    # The audit record keeps what the block was, not its bytes a second time.
    assert [_text, %{"type" => "image", "attached" => true, "size" => size} = record] =
             result.content

    assert size == byte_size(@png)
    refute Map.has_key?(record, "data")
  end

  test "an embedded PDF resource becomes a named document" do
    result =
      through_mcp(%{
        "content" => [
          %{
            "type" => "resource",
            "resource" => %{
              "uri" => "file:///reports/q3.pdf",
              "mimeType" => "application/pdf",
              "blob" => Base.encode64(@pdf)
            }
          }
        ]
      })

    assert [%{"kind" => "document", "path" => "q3.pdf"}] = result.attachments
    assert result.model_text =~ "[document: q3.pdf (application/pdf"
    refute result.model_text =~ "cannot show you"
    assert [%{"resource" => resource}] = result.content
    refute Map.has_key?(resource, "blob")
  end

  test "what cannot be attached keeps its block and its sentence" do
    result =
      through_mcp(%{
        "content" => [
          %{"type" => "audio", "data" => Base.encode64("RIFF"), "mimeType" => "audio/wav"},
          %{"type" => "image", "data" => "%%% not base64 %%%", "mimeType" => "image/png"}
        ]
      })

    assert result.attachments == []
    assert result.model_text =~ "[audio content, which lemieux cannot show you]"
    assert result.model_text =~ "[image content, which lemieux cannot show you]"
  end
end
