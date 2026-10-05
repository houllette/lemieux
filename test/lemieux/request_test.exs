defmodule Lemieux.RequestTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Request

  defp request(entries), do: Request.new("test:model", entries: entries)

  defp attached(bytes) do
    Entry.new(:user, %{
      "text" => "what is this",
      "attachments" => [
        %{
          "kind" => "image",
          "path" => "shot.png",
          "media_type" => "image/png",
          "data" => Base.encode64(String.duplicate("x", bytes))
        }
      ]
    })
  end

  describe "estimated_tokens/1" do
    test "grows with the conversation it is weighing" do
      short = request([Entry.new(:user, %{"text" => "hi"})])
      long = request([Entry.new(:user, %{"text" => String.duplicate("hi ", 500)})])

      assert Request.estimated_tokens(long) > Request.estimated_tokens(short)
    end

    test "is never zero, so admission always asks for something" do
      assert Request.estimated_tokens(request([])) > 0
    end

    test "adds the output the request has asked room for" do
      entries = [Entry.new(:user, %{"text" => "hi"})]
      bounded = Request.new("test:model", entries: entries, params: [max_tokens: 4_000])

      assert Request.estimated_tokens(bounded) - Request.estimated_tokens(request(entries)) ==
               4_000
    end

    test "weighs an image as what it costs, not as the base64 it is stored in" do
      # One byte per encoded byte is pessimistic-but-adequate for prose and
      # catastrophic for base64: a one-megabyte screenshot would read as a
      # million tokens, and the session would refuse — on budget or on the
      # rate limiter — to send a request it could comfortably afford.
      assert Request.estimated_tokens(request([attached(1_000_000)])) ==
               Request.estimated_tokens(request([attached(100)]))
    end

    test "still counts an attached file's text, which the model really does read" do
      bare = Entry.new(:user, %{"text" => "explain @a.ex"})

      attached =
        Entry.new(:user, %{
          "text" => "explain @a.ex",
          "attachments" => [
            %{"kind" => "file", "path" => "a.ex", "text" => String.duplicate("line\n", 400)}
          ]
        })

      assert Request.estimated_tokens(request([attached])) >
               Request.estimated_tokens(request([bare])) + 1_000
    end
  end
end
