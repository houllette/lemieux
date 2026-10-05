defmodule Lemieux.WebFetch.MarkdownTest do
  use ExUnit.Case, async: true
  alias Lemieux.WebFetch.Markdown

  test "preserves Markdown while extracting its title and ordered links outside code" do
    text = """
    # Installation

    Read [the guide](/guide), then [API][api].
    [api]: https://example.com/api "Reference"
    https://example.com/llms.txt
    ```elixir
      fake = "https://example.com/fake"
    ```
    [Duplicate](/guide#part) and [Here](#top).
    """

    page = Markdown.to_text(text, "https://example.com/")
    assert page.text == String.trim(text)
    assert page.title == "Installation"

    assert page.links == [
             "https://example.com/guide",
             "https://example.com/api",
             "https://example.com/llms.txt"
           ]
  end
end
