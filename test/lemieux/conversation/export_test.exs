defmodule Lemieux.Conversation.ExportTest do
  use ExUnit.Case, async: true

  alias Lemieux.Conversation.Export
  alias Lemieux.Entry

  test "a stop hook's message is exported as lmx speaking, without its tag" do
    entries = [
      Entry.new(:user, %{"text" => "migrate the module"}),
      Entry.new(:assistant, %{"content" => [%{"type" => "text", "text" => "Step 1 is done."}]}),
      Entry.new(:user, %{
        "text" => "[lmx continue] You ended your turn, but your plan still has open tasks:",
        "stop_hook" => true
      })
    ]

    markdown = Export.markdown(%{id: "01M3TESTEXPORT0000000000000", entries: entries})

    assert markdown =~ "## You\n\nmigrate the module"
    assert markdown =~ "## lmx · sent back\n\nYou ended your turn"
    refute markdown =~ "## You\n\n[lmx continue]"
  end
end
