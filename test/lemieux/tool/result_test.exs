defmodule Lemieux.Tool.ResultTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tool.Result

  test "keeps renderer-neutral structure separate from bounded model text" do
    result =
      Result.new("Found two tickets",
        structured_content: %{"tickets" => [%{"id" => 1}, %{"id" => 2}]},
        content: [%{"type" => "resource_link", "uri" => "ticket://1"}],
        artifacts: [%{"uri" => "artifact://report"}],
        cost: %{"usd" => 0.01}
      )

    assert result.model_text == "Found two tickets"
    assert to_string(result) == "Found two tickets"
    assert result.structured_content["tickets"] |> length() == 2
    assert result.cost == %{"usd" => 0.01}

    assert Result.to_map(result)["content"] == [
             %{"type" => "resource_link", "uri" => "ticket://1"}
           ]
  end

  test "replaces over-budget structure with reconstructible truncation evidence" do
    result = Result.new("ok", structured_content: %{"body" => String.duplicate("x", 2_000)})
    limited = Result.limit(result, 200)

    assert limited.structured_content["truncated"] == true
    assert limited.structured_content["bytes"] > 2_000
    assert byte_size(limited.structured_content["sha256"]) == 64
    assert limited.model_text =~ "structured result exceeded"
  end

  test "a streamed failure remains an error and keeps output received before it" do
    assert {:error, result} =
             Lemieux.Tool.collect_result(
               {:stream, ["started\n", {:error, :worker_down}]},
               fn _chunk -> :ok end,
               1_000
             )

    assert result.model_text =~ "started"
    assert result.model_text =~ "worker_down"
  end

  describe "attachments" do
    alias Lemieux.Tool.Attachment

    @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 1::32, 1::32, 8, 6, 0, 0, 0>>

    # A screenshot is far larger than the audit budget, and used to take every
    # structured field down with it when it was carried as a content block.
    test "survive an audit budget they would exceed, which still bounds the evidence" do
      screenshot = Attachment.new(:image, "image/png", @png <> :binary.copy(<<0>>, 50_000))

      result =
        Result.new("shot taken",
          structured_content: %{"body" => String.duplicate("x", 2_000)},
          attachments: [screenshot]
        )

      limited = Result.limit(result, 500)

      assert limited.attachments == [screenshot]
      assert limited.structured_content["truncated"] == true
      refute Map.has_key?(Result.to_map(result), "attachments")
    end

    test "must be attachment-shaped" do
      assert_raise ArgumentError, fn ->
        Result.new("x", attachments: [%{"kind" => "image", "data" => "not a media type"}])
      end
    end

    test "collection applies the attachment limits and names what was left out" do
      small = Attachment.new(:image, "image/png", @png, path: "a.png")
      huge = %{Attachment.new(:image, "image/png", @png, path: "b.png") | "size" => 9_000_000}

      assert {:ok, result} =
               Lemieux.Tool.collect_result(
                 {:ok, Result.new("two shots", attachments: [small, huge])},
                 fn _chunk -> :ok end,
                 10_000
               )

      assert result.attachments == [small]
      assert result.model_text =~ "two shots"
      assert result.model_text =~ "image b.png is 9.0 MB"
    end
  end
end
