defmodule Lemieux.CLI.ACP.WireTest do
  use ExUnit.Case, async: true

  alias Lemieux.CLI.ACP.Wire

  test "v2 diffs carry structured operations and a complete text patch" do
    event = {:diff, "/workspace/a file.txt", "before\n\n", "after"}
    packet = Wire.tool_event("edit", event, 2)
    assert [%{"type" => "diff", "changes" => [change], "patch" => patch}] = packet["content"]

    assert change == %{
             "operation" => "modify",
             "path" => "/workspace/a file.txt",
             "fileType" => "text"
           }

    assert patch["format"] == "git_patch"
    assert patch["text"] =~ "@@ -1,2 +1,1 @@\n-before\n-\n+after\n\\ No newline at end of file\n"
    assert patch["text"] =~ "\"a//workspace/a file.txt\""

    assert [%{"oldText" => "before\n\n", "newText" => "after"}] =
             Wire.tool_event("edit", event, 1)["content"]
  end

  test "v2 new files are additions with an empty original side" do
    assert [%{"changes" => [%{"operation" => "add"}], "patch" => patch}] =
             Wire.tool_event("write", {:diff, "/workspace/new.txt", nil, "created\n"}, 2)[
               "content"
             ]

    assert patch["text"] =~ "--- /dev/null\n"
    assert patch["text"] =~ "@@ -0,0 +1,1 @@\n+created\n"
  end
end
