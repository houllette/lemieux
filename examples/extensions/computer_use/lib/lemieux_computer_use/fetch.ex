defmodule LemieuxComputerUse.Fetch do
  @moduledoc """
  HTTP-first fetch with explicitly host-enabled Wallaby rendering for JS shells.

  HTTP failures, policy denials, content-type refusals and byte caps do not
  trigger a browser retry. Only a successful HTML extraction's rendering hint
  can escalate, through a separate `web_fetch_render` tool approval. A denied
  or unsuccessful render retains the labelled static result and its limits.
  """
  @behaviour Lemieux.Tool.Configured
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.WebFetch
  defstruct [:http, opts: []]

  @spec new(http :: WebFetch.t(), opts :: keyword()) :: struct()
  def new(http, opts), do: %__MODULE__{http: http, opts: opts}

  @impl true
  def name(_), do: "web_fetch"
  @impl true
  def description(tool),
    do:
      WebFetch.description(tool.http) <>
        " When enabled by the host, JavaScript shells may be rendered in a fresh browser under a separate approval."

  @impl true
  def schema(_), do: WebFetch.schema()
  @impl true
  def metadata(tool) do
    metadata = WebFetch.metadata(tool.http)

    metadata =
      if Keyword.get(tool.opts, :browser_fetch, true),
        do: %{
          metadata
          | effects: %{
              class: "external",
              resource_types: ["public_web", "browser"],
              external_cost: "unknown",
              idempotent: false,
              retryable: false
            }
        },
        else: metadata

    put_in(
      metadata,
      [:runtime, :timeout_ms],
      metadata.runtime.timeout_ms + Keyword.get(tool.opts, :render_timeout_ms, 10_000)
    )
  end

  @impl true
  def run(tool, args, context) do
    case WebFetch.run(tool.http, args, context) do
      {:ok, result} -> maybe_render(tool, result, context)
      error -> error
    end
  end

  defp maybe_render(tool, result, context) do
    if Keyword.get(tool.opts, :browser_fetch, true) and
         get_in(result.structured_content, ["extraction", "needs_render"]) == true and
         not result.structured_content["truncated"] do
      render(tool, result, context)
    else
      {:ok, result}
    end
  end

  defp render(tool, original, context) do
    url = original.structured_content["url"]

    renderer = %LemieuxComputerUse.RenderedFetch{
      url: url,
      opts: tool.opts,
      max_bytes: tool.http.max_body_bytes,
      max_chars: tool.http.max_text_chars
    }

    call = %{
      id: "#{Map.get(context, :call_id, "fetch")}-render",
      name: "web_fetch_render",
      arguments: %{"url" => url}
    }

    context = Map.put_new(context, :tool_output_bytes, 200_000)
    receipt = Lemieux.Tools.run([renderer], Map.get(context, :hooks, []), call, context)

    if receipt.error? or get_in(receipt, [:structured_content, "source"]) != "browser" do
      {:ok,
       %{
         original
         | model_text:
             original.model_text <>
               "\n[Browser rendering #{receipt.outcome}; returning the limited static extraction]",
           structured_content:
             Map.put(original.structured_content, "rendering", %{
               "outcome" => to_string(receipt.outcome)
             })
       }}
    else
      evidence =
        Map.merge(receipt.structured_content, %{
          "http_fetch" => Map.delete(original.structured_content, "text"),
          "bytes" => original.structured_content["bytes"],
          "requested_url" => original.structured_content["requested_url"],
          "browser_network_bytes" => nil
        })

      {:ok, Result.new(receipt.output, structured_content: evidence)}
    end
  end
end
