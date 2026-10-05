defmodule Lemieux.Extensions.MCPDiscovery do
  @moduledoc """
  Optional on-demand MCP schema exposure, with ordinary remote-tool execution.

  The host connects MCP servers as usual. Only `mcp_discover` and pinned remote
  schemas enter the initial request. Search reads the current authorized catalog;
  enable replaces the bounded selection for the next request. Remote calls still
  use their original names, descriptors, budgets, hooks and receipts. No wrapper
  dispatch or busy catalog mutation is involved.

  Selection is bound to a fresh host binding, descriptor digest and expiration.
  Reapplying the extension on resume invalidates old selections. No credentials
  or executable catalog are cached on disk. Hosts must rebind after authentication
  changes and refresh their MCP connection when a server changes its catalog.
  This saves model context, not MCP startup/list-tools network work.

  ## When to hide schemas: `:mode`

    * `:on` (the default when applied directly) — always: only `mcp_discover`
      and pinned schemas reach the request.
    * `:auto` — only while the remote schemas would cost more than
      `:threshold_bytes` of the request. Below it every remote tool is offered
      as usual and `mcp_discover` is left out, since it would only be noise
      beside tools the model can already see; above it this behaves as `:on`.
      The size is measured on every request, so a server that connects late
      or grows its catalog switches the mode when it happens. The threshold
      defaults to a tenth of `:context_window` tokens (at four bytes a token)
      when one is given, else 40,000 bytes.
    * `:off` — the extension does nothing, so a configuration can name it
      without applying it.

  A handful of small servers do not need this, and hiding their schemas makes
  a model spend a turn discovering tools it could have simply been shown;
  a dozen large ones crowd out the conversation. `:auto` is how a host ships
  it on without choosing between those cases for every person.
  """
  @behaviour Lemieux.Extension
  @behaviour Lemieux.Tool.Configured
  import Kernel, except: [apply: 2]

  alias Lemieux.Harness
  alias Lemieux.Session
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tool.Result

  defstruct [
    :binding,
    ttl_ms: 300_000,
    max_tools: 8,
    pinned: [],
    mode: :on,
    threshold_bytes: 40_000
  ]

  @namespace "lemieux.mcp.selection"
  @default_threshold 40_000

  @impl Lemieux.Extension
  def apply(harness, opts) do
    case Keyword.get(opts, :mode, :on) do
      :off -> harness
      mode when mode in [:on, :auto] -> equip(harness, mode, opts)
      other -> raise ArgumentError, "invalid MCP discovery mode: #{inspect(other)}"
    end
  end

  defp equip(harness, mode, opts) do
    tool =
      struct!(
        __MODULE__,
        opts
        |> Keyword.take([:ttl_ms, :max_tools, :pinned])
        |> Keyword.merge(mode: mode, threshold_bytes: threshold(opts))
      )

    unless is_integer(tool.ttl_ms) and tool.ttl_ms > 0 and tool.max_tools in 1..32 and
             is_list(tool.pinned) and Enum.all?(tool.pinned, &is_binary/1) and
             is_integer(tool.threshold_bytes) and tool.threshold_bytes > 0,
           do: raise(ArgumentError, "invalid MCP discovery limits")

    tool = %{tool | binding: Lemieux.ID.generate()}

    harness
    |> Harness.update_tools(&(&1 ++ [tool]))
    |> Harness.append_hooks(
      prepare_next_turn: &prepare(tool, &1, &2),
      before_tool_call: &authorize(tool, &1, &2)
    )
  end

  defp threshold(opts) do
    case {Keyword.get(opts, :threshold_bytes), Keyword.get(opts, :context_window)} do
      {bytes, _window} when is_integer(bytes) -> bytes
      {nil, window} when is_integer(window) and window > 0 -> div(window * 4, 10)
      _default -> @default_threshold
    end
  end

  @doc """
  Whether the remote tools in `tools` cost more than `threshold` bytes of a
  request: their names, descriptions and schemas as JSON.
  """
  @spec over_threshold?(tools :: [Tool.t()], threshold :: pos_integer()) :: boolean()
  def over_threshold?(tools, threshold) when is_list(tools) and is_integer(threshold) do
    tools
    |> Enum.filter(&remote?/1)
    |> Enum.reduce_while(0, fn tool, size ->
      size =
        size +
          byte_size(
            JSON.encode!(%{
              "name" => Tool.name(tool),
              "description" => Tool.description(tool),
              "schema" => Tool.schema(tool)
            })
          )

      if size > threshold, do: {:halt, size}, else: {:cont, size}
    end)
    |> Kernel.>(threshold)
  end

  @impl Lemieux.Tool.Configured
  def name(_tool), do: "mcp_discover"
  @impl Lemieux.Tool.Configured
  def description(_tool),
    do:
      "Search authorized MCP tools, then enable exact names to receive their schemas on the next request. Enabling replaces your selection."

  @impl Lemieux.Tool.Configured
  def schema(_tool),
    do: %{
      "type" => "object",
      "required" => ["action"],
      "additionalProperties" => false,
      "properties" => %{
        "action" => %{"type" => "string", "enum" => ["search", "enable"]},
        "query" => %{"type" => "string"},
        "names" => %{"type" => "array", "items" => %{"type" => "string"}}
      }
    }

  @impl Lemieux.Tool.Configured
  def run(tool, %{"action" => "search"} = args, context) do
    query = Map.get(args, "query", "")

    if is_binary(query) do
      matches =
        context.session
        |> Session.catalog()
        |> Enum.filter(
          &(remote?(&1) and
              String.contains?(
                String.downcase(Tool.name(&1) <> " " <> Tool.description(&1)),
                String.downcase(query)
              ))
        )

      results =
        matches
        |> Enum.take(tool.max_tools)
        |> Enum.map(
          &%{"name" => Tool.name(&1), "description" => String.slice(Tool.description(&1), 0, 400)}
        )

      {:ok,
       Result.new(
         JSON.encode!(%{"matches" => results, "more" => length(matches) > length(results)})
       )}
    else
      {:error, "query must be text"}
    end
  end

  def run(tool, %{"action" => "enable", "names" => names}, context) when is_list(names) do
    catalog =
      context.session
      |> Session.catalog()
      |> Enum.filter(&remote?/1)
      |> Map.new(&{Tool.name(&1), &1})

    if length(names) <= tool.max_tools and length(Enum.uniq(names)) == length(names) and
         Enum.all?(names, &Map.has_key?(catalog, &1)) do
      selected = Map.new(names, &{&1, Tool.descriptor(catalog[&1]).digest})

      with {:ok, current} <- Session.document(context.session, @namespace),
           {:ok, _document} <-
             Session.put_document(context.session, @namespace, current.revision, %{
               "binding" => tool.binding,
               "expires_at" => now() + tool.ttl_ms,
               "selected" => selected
             }) do
        {:ok,
         "Enabled for subsequent requests: #{Enum.join(names, ", ")}. Call these tools by their own names."}
      else
        {:error, _reason} -> {:error, "selection changed concurrently; enable again"}
      end
    else
      {:error, "enable requires unique authorized remote names within the configured limit"}
    end
  end

  def run(_tool, _args, _context), do: {:error, "use search or enable"}

  @doc false
  @spec prepare(tool :: struct(), request :: Lemieux.Request.t(), context :: map()) :: term()
  def prepare(%{mode: :auto} = tool, request, context) do
    if over_threshold?(request.tools, tool.threshold_bytes),
      do: prepare(%{tool | mode: :on}, request, context),
      else: {:ok, %{request | tools: Enum.reject(request.tools, &discovery?/1)}}
  end

  def prepare(tool, request, context) do
    selected = selection(tool, context.session)

    {:ok,
     %{
       request
       | tools: Enum.filter(request.tools, &(not remote?(&1) or enabled?(tool, &1, selected)))
     }}
  end

  @doc false
  @spec authorize(tool :: struct(), call :: map(), context :: map()) :: term()
  def authorize(tool, _call, %{tool_descriptor: %{"origin" => %{"type" => "mcp"}}} = context) do
    cond do
      # Below the threshold every schema was offered, so nothing is gated.
      tool.mode == :auto and
          not over_threshold?(Session.catalog(context.session), tool.threshold_bytes) ->
        :allow

      allowed_descriptor?(tool, context.tool_descriptor, selection(tool, context.session)) ->
        :allow

      true ->
        {:deny, "MCP schema selection expired or changed; use mcp_discover to enable it again"}
    end
  end

  def authorize(_tool, _call, _context), do: :allow

  defp discovery?(tool), do: Tool.name(tool) == "mcp_discover"

  defp enabled?(tool, executor, selected),
    do:
      allowed_descriptor?(
        tool,
        Descriptor.to_map(Tool.descriptor(executor)),
        selected
      )

  defp allowed_descriptor?(tool, descriptor, selected) do
    name = descriptor["identity"]["name"]
    name in tool.pinned or selected[name] == descriptor["digest"]
  end

  defp selection(tool, session) do
    case Session.document(session, @namespace) do
      {:ok, %{value: %{"binding" => binding, "expires_at" => expires, "selected" => selected}}}
      when binding == tool.binding and is_integer(expires) and is_map(selected) ->
        if expires > now(), do: selected, else: %{}

      _other ->
        %{}
    end
  end

  defp remote?(tool), do: Tool.descriptor(tool).origin["type"] == "mcp"
  defp now, do: System.system_time(:millisecond)
end
