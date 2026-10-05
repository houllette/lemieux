defmodule LemieuxComputerUse.RenderedFetch do
  @moduledoc """
  Bounded rendering in a fresh owned browser, without model calls or input.

  Selected and observed document URLs are checked against the host policy.
  As with interactive browser use, subresource/redirect traffic needs host
  egress isolation; the browser does not inherit the HTTP fetcher's DNS pinning.
  Reported rendered bytes describe the DOM projection, not network transfer.
  """
  @behaviour Lemieux.Tool.Configured
  alias LemieuxComputerUse.Policy
  alias Lemieux.Tool.Result
  alias Lemieux.WebFetch.HTML
  defstruct [:url, opts: [], max_bytes: 262_144, max_chars: 4000]

  @impl true
  def name(_), do: "web_fetch_render"
  @impl true
  def description(_),
    do: "Render a permitted JavaScript page in a fresh browser; no clicks or typing"

  @impl true
  def schema(_),
    do: %{
      "type" => "object",
      "properties" => %{"url" => %{"type" => "string"}},
      "required" => ["url"]
    }

  @impl true
  def metadata(tool),
    do: %{
      effects: %{class: "external", resource_types: ["browser"], external_cost: "unknown"},
      runtime: %{
        timeout_ms: Keyword.get(tool.opts, :render_timeout_ms, 10_000),
        max_output_bytes: tool.max_chars * 4 + 16_384
      }
    }

  @impl true
  def run(tool, args, _context) do
    with true <- args == %{"url" => tool.url}, :ok <- Policy.check(tool.url, tool.opts) do
      owned(tool)
    else
      _ -> {:error, "Browser fetch URL refused or rewritten"}
    end
  end

  defp owned(tool) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    try do
      task = Task.Supervisor.async_nolink(supervisor, fn -> render(tool) end)

      case Task.yield(task, Keyword.get(tool.opts, :render_timeout_ms, 10_000)) ||
             Task.shutdown(task, :brutal_kill) do
        {:ok, result} -> result
        _ -> {:error, "Browser rendering timed out or failed"}
      end
    after
      Supervisor.stop(supervisor)
    end
  end

  defp render(tool) do
    driver = Keyword.get(tool.opts, :render_driver, LemieuxComputerUse.Wallaby)

    with {:ok, session} <- driver.open(tool.url, tool.opts) do
      try do
        deadline =
          System.monotonic_time(:millisecond) + Keyword.get(tool.opts, :render_wait_ms, 2000)

        await_document(driver, session, tool, deadline, nil)
      after
        driver.close(session)
      end
    end
  end

  defp await_document(driver, session, tool, deadline, previous) do
    with {:ok, document} <- driver.document(session, max_bytes: tool.max_bytes),
         :ok <- Policy.check(document["url"], tool.opts) do
      fingerprint = :crypto.hash(:sha256, document["html"])

      cond do
        document["ready"] and fingerprint == previous ->
          result(document, tool)

        System.monotonic_time(:millisecond) >= deadline ->
          {:error, "Browser content did not settle before its deadline"}

        true ->
          receive do
          after
            100 -> :ok
          end

          await_document(driver, session, tool, deadline, fingerprint)
      end
    end
  end

  defp result(document, tool) do
    page = HTML.to_text(document["html"], base: document["url"])
    text = String.slice(page.text, 0, tool.max_chars)

    truncated =
      document["truncated"] or page.parser_truncated or String.length(page.text) > tool.max_chars

    evidence = %{
      "url" => document["url"],
      "title" => page.title,
      "text" => text,
      "links" => page.links,
      "source" => "browser",
      "status" => nil,
      "content_type" => "text/html",
      "truncated" => truncated,
      "rendered_bytes" => byte_size(document["html"]),
      "extraction" => %{
        "method" => page.extraction,
        "readable_chars" => String.length(page.text),
        "needs_render" => false,
        "truncated" => page.parser_truncated
      }
    }

    output =
      Enum.join(
        [
          Lemieux.Tools.WebFetch.banner(document["url"]),
          "Source: browser-rendered DOM (HTTP status and network byte count unavailable)",
          "Title: #{page.title || "(none)"}",
          text,
          if(truncated, do: "[rendered content truncated]", else: ""),
          "Links:\n" <> Enum.map_join(page.links, "\n", &("- " <> &1))
        ],
        "\n\n"
      )

    {:ok, Result.new(output, structured_content: evidence)}
  end
end
