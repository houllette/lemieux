defmodule Lemieux.WebFetch.HTMLTest do
  use ExUnit.Case, async: true

  alias Lemieux.WebFetch.HTML

  @page """
  <!DOCTYPE html>
  <html><head>
    <title> Tidepool &amp; Friends </title>
    <style>body { color: red }</style>
    <script>window.secret = "ignore me"; alert('x');</script>
  </head>
  <body>
    <!-- a comment the model should never see -->
    <h1>Overview</h1>
    <p>Tidepool listens on port <b>7433</b> by default.<br>Second line.</p>
    <noscript>Enable JavaScript to read the assistant instructions.</noscript>
    <ul><li>one</li><li>two &lt;three&gt;</li></ul>
    <table><tr><td>a</td><td>b</td></tr></table>
    <p>Caf&eacute; &#233; &#x00E9; &copy; &bogus; &#xD800;</p>
    <a href="/docs/config.html">Config</a>
    <a href='https://other.example/page#frag'>Other</a>
    <a href="#top">Top</a>
    <a href="mailto:someone@example.com">Mail</a>
    <a href="javascript:alert(1)">JS</a>
    <a href="/docs/config.html">Duplicate</a>
  </body></html>
  """

  test "drops scripts, styles, noscript and comments, and keeps prose in order" do
    %{text: text} = HTML.to_text(@page, base: "https://docs.example/docs/index.html")

    refute text =~ "ignore me"
    refute text =~ "alert"
    refute text =~ "color: red"
    refute text =~ "never see"
    refute text =~ "assistant instructions"

    assert text =~ "Overview\n"
    assert text =~ "Tidepool listens on port 7433 by default.\nSecond line."
    assert text =~ "one\n\ntwo <three>"
    assert text =~ "a b"
  end

  test "keeps the title, decoded and trimmed" do
    assert %{title: "Tidepool & Friends"} = HTML.to_text(@page)
    assert %{title: nil} = HTML.to_text("<p>no title</p>")
  end

  test "decodes numeric and common named entities but leaves unknown or invalid ones alone" do
    %{text: text} = HTML.to_text(@page)
    assert text =~ "Café é é © &bogus; &#xD800;"
    assert HTML.decode_entities("a &lt; b &amp;&amp; c &gt; d &nbsp;e") == "a < b && c > d  e"
  end

  test "collects absolute http(s) link targets once each, resolving relative ones" do
    %{links: links} = HTML.to_text(@page, base: "https://docs.example/docs/index.html")

    assert links == [
             "https://docs.example/docs/config.html",
             "https://other.example/page#frag"
           ]

    assert %{links: ["https://other.example/page#frag"]} = HTML.to_text(@page)
  end

  test "caps the links appendix at twenty" do
    html = Enum.map_join(1..30, "", &~s(<a href="https://example.com/#{&1}">#{&1}</a>))
    assert %{links: links} = HTML.to_text(html)
    assert length(links) == 20
    assert List.last(links) == "https://example.com/20"
  end

  test "collapses runs of whitespace and blank lines" do
    html = "<p>  a   b </p>\n\n\n\n<p>c</p><div></div><div></div><p>d</p>"
    assert %{text: "a b\n\nc\n\nd"} = HTML.to_text(html)
  end

  test "an unterminated script is discarded through EOF instead of leaking hydration data" do
    %{text: text} = HTML.to_text("<p>before</p><script>var x = 1; <p>after</p>")
    assert text =~ "before"
    refute text =~ "var x = 1;"
    refute text =~ "<script>"
  end

  test "main content and its links outrank a large nested navigation shell" do
    navigation =
      Enum.map_join(1..30, "", &~s(<div><a href="/nav/#{&1}">Navigation #{&1}</a></div>))

    html = """
    <head><title>Guide</title></head><body><nav>#{navigation}</nav>
    <main><div><h1>Install</h1><p>Run the installer.</p>
    <a href="/guide/setup">Setup</a><a href="/guide/setup#details">Again</a>
    <div hidden><a href="/hidden">Hidden trap</a></div>
    <aside>Advertising</aside></div></main><footer>Legal noise</footer></body>
    """

    page = HTML.to_text(html, base: "https://example.com/guide")
    assert page.text =~ "Run the installer."
    refute page.text =~ "Navigation"
    refute page.text =~ "Hidden trap"
    refute page.text =~ "Advertising"
    assert hd(page.links) == "https://example.com/guide/setup"
    assert Enum.count(page.links, &String.contains?(&1, "/guide/setup")) == 1
    refute "https://example.com/hidden" in page.links
    assert page.extraction == "main"
  end

  test "articles, quoted tag attributes and preformatted code retain their structure" do
    page =
      HTML.to_text(
        ~s(<header>Site links</header><div role="main" title="a > b"><article><h1>Example</h1><pre>if true do\n  :ok\nend</pre></article></div>)
      )

    assert page.text =~ "if true do\n  :ok\nend"
    refute page.text =~ "Site links"
    assert page.extraction == "article"
  end

  test "render hints distinguish a JavaScript shell from an ordinary short document" do
    assert %{needs_render: true, text: "Loading..."} =
             HTML.to_text(~s(<main>Loading...</main><script src="/app.js"></script>))

    assert %{needs_render: false} = HTML.to_text("<main>Small but valid page</main>")

    assert %{text: "Visible"} =
             HTML.to_text(~s(<div aria-hidden="true"><div>Hidden</div></div><p>Visible</p>))
  end

  test "same-page fragments and credentialed URLs are not crawl targets" do
    page =
      HTML.to_text(
        ~s(<a href="https://example.com/guide#part">Here</a><a href="https://user:secret@elsewhere.test/">Login</a><a href="/next">Next</a>),
        base: "https://example.com/guide"
      )

    assert page.links == ["https://example.com/next"]
  end

  test "pathological nesting is bounded and explicitly marked" do
    page = HTML.to_text("<p>Readable prefix</p>" <> String.duplicate("<div>", 200) <> "Too deep")
    assert page.parser_truncated
    assert page.text == "Readable prefix"
    refute page.text =~ "Too deep"
  end

  test "article links precede repository or site controls inside the same main container" do
    html =
      ~s(<main><a href="/login">Log in</a><article><p>Guide</p><a href="/install">Install</a></article></main>)

    assert %{links: ["https://example.com/install", "https://example.com/login"]} =
             HTML.to_text(html, base: "https://example.com/")
  end
end
