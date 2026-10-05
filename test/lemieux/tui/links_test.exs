defmodule Lemieux.TUI.LinksTest do
  use ExUnit.Case, async: true

  alias ExRatatui.Text.{Line, Span}
  alias Lemieux.TUI.Links
  alias Lemieux.TUI.RichText

  defp view(text), do: %{rows: RichText.lines([{:model, text}], 200), bottom: 0}

  test "opens a Markdown label and a bare URL at the clicked cell" do
    text = "Read [guide](https://example.com/guide) or https://example.org/x."
    assert Links.target_at(view(text), {0, 8}, nil) == "https://example.com/guide"
    assert Links.target_at(view(text), {0, 46}, nil) == "https://example.org/x"
    assert Links.target_at(view(text), {0, 0}, nil) == nil
    assert Links.target_at(view(text), {1, 8}, nil) == nil
  end

  test "a rendered link opens from its label or destination" do
    text = "Visit [Google](https://google.com) today"
    assert Links.target_at(view(text), {0, 9}, nil) == "https://google.com"
    assert Links.target_at(view(text), {0, 23}, nil) == "https://google.com"
    assert Links.target_at(view(text), {0, 0}, nil) == nil
  end

  test "only existing local files resolve and other URI schemes are ignored" do
    path = Path.join(System.tmp_dir!(), "lmx-link-#{System.unique_integer([:positive])}.ex")
    File.write!(path, ":ok")
    on_exit(fn -> File.rm(path) end)

    assert Links.target_at(view("Open #{path}"), {0, 6}, nil) == path
    assert Links.target_at(view("Open [file](#{path})"), {0, 8}, nil) == path
    assert Links.target_at(view("javascript:alert(1)"), {0, 5}, nil) == nil
    assert Links.target_at(view("./missing.ex"), {0, 4}, Path.dirname(path)) == nil
  end

  test "an ordinary word stays inert beside real local documentation links" do
    text = "Use `lmx`: docs/getting-started.md"
    row = view(text)

    assert Links.target_at(row, {0, 5}, File.cwd!()) == nil

    assert Links.target_at(row, {0, 12}, File.cwd!()) ==
             Path.join(File.cwd!(), "docs/getting-started.md")
  end

  test "macOS opens Markdown in a text editor instead of its file association" do
    assert Links.opener_command("/repo/docs/guide.md", {:unix, :darwin}) ==
             {"open", ["-t", "/repo/docs/guide.md"]}

    assert Links.opener_command("https://example.com", {:unix, :darwin}) ==
             {"open", ["https://example.com"]}

    assert Links.opener_command("https://example.com/guide.md", {:unix, :darwin}) ==
             {"open", ["https://example.com/guide.md"]}
  end

  test "a URL stays clickable on both sides of a soft wrap" do
    style = %ExRatatui.Style{modifiers: [:underlined]}

    rows = [
      Line.new([Span.new("see "), Span.new("https://exam", style: style)]),
      Line.new([Span.new("ple.com/guide", style: style)])
    ]

    view = %{rows: rows, bottom: 0}

    assert Links.target_at(view, {1, 6}, nil, 16) == "https://example.com/guide"
    assert Links.target_at(view, {0, 3}, nil, 16) == "https://example.com/guide"
  end
end
