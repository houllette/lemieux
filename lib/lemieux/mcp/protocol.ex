defmodule Lemieux.MCP.Protocol do
  @moduledoc """
  The wire format of MCP, as pure functions.

  Everything here is a map in and a map out: no transport, no process, no
  network. That is deliberate — the interesting part of speaking a protocol is
  the decisions (which era is this server, which version do we agree on, is
  this result an answer or an error), and decisions tested through a socket
  are decisions tested slowly and flakily.

  ## Two eras

  Revision `2026-07-28` made MCP stateless: it removed the
  `initialize`/`notifications/initialized` handshake, and every request now
  carries its own protocol version, client identity and capabilities in
  `_meta`. Everything released before it — `2025-11-25` and earlier — opens a
  session with `initialize` and says nothing per request.

  lemieux speaks both, because the specification is new and the servers people
  actually run are not. The specification calls these **modern** and
  **legacy**, and so does this module.

  ## Telling them apart

  The rule is the specification's, and it is worth stating exactly, because
  the obvious guess is wrong: **a recognised modern error means a modern
  server**, not a broken one. A server that answers `server/discover` with
  `UnsupportedProtocolVersionError` is modern and disagrees about versions, so
  the client retries with one of the versions the error names. Any *other*
  error means a server that has never heard of `server/discover`, so the
  client falls back to `initialize`.

  Guessing the other way — treating an unrecognised error as modern — leaves a
  legacy server being sent metadata it will not understand, on every request,
  with no way back.
  """

  alias Lemieux.MCP.RemoteTool
  alias Lemieux.Tool.Attachment
  alias Lemieux.Tool.Result

  @modern "2026-07-28"

  # Newest first: `choose/1` takes the first the server also names.
  @legacy ~w(2025-11-25 2025-06-18 2025-03-26 2024-11-05)
  @versions [@modern | @legacy]

  @unsupported_version -32_022

  @meta_version "io.modelcontextprotocol/protocolVersion"
  @meta_client_info "io.modelcontextprotocol/clientInfo"
  @meta_capabilities "io.modelcontextprotocol/clientCapabilities"

  @typedoc "Which era of the protocol a server speaks."
  @type era :: :modern | :legacy

  @doc "The revision lemieux prefers."
  @spec modern_version() :: String.t()
  def modern_version, do: @modern

  @doc "Every revision lemieux can speak, newest first."
  @spec versions() :: [String.t()]
  def versions, do: @versions

  @doc "The newest revision lemieux speaks that predates the stateless rewrite."
  @spec newest_legacy_version() :: String.t()
  def newest_legacy_version, do: hd(@legacy)

  @doc """
  Builds a JSON-RPC request for the given era.

  A modern request carries `_meta`; a legacy one carries nothing but its
  params, because in that era the handshake said all of this once.
  """
  @spec request(era :: era(), method :: String.t(), params :: map(), opts :: keyword()) :: map()
  def request(era, method, params \\ %{}, opts) do
    %{
      "jsonrpc" => "2.0",
      "id" => Keyword.fetch!(opts, :id),
      "method" => method,
      "params" => params(era, params, opts)
    }
  end

  defp params(:legacy, params, _opts), do: params

  # Merged over whatever `_meta` the caller put in the params rather than
  # replacing it: a `tools/call` carries its `progressToken` there, and a
  # modern request that dropped it would never hear about its own progress.
  defp params(:modern, params, opts) do
    meta = %{
      @meta_version => Keyword.get(opts, :version, @modern),
      @meta_client_info => %{"name" => "lemieux", "version" => Lemieux.version()},
      # A server MUST NOT ask for input of a kind the client has not declared, so this
      # list is exactly what lemieux can satisfy. Form-mode elicitation is a question
      # with a schema, which a host already knows how to answer
      # (`Lemieux.Session.answer/3`). Deliberately undeclared: `url` mode needs a
      # browser and a consent step a library cannot assume, sampling would mean lending
      # the server lemieux's model, and roots is deprecated.
      @meta_capabilities => %{"elicitation" => %{"form" => %{}}}
    }

    Map.update(params, "_meta", meta, &Map.merge(json_map(&1), meta))
  end

  @doc """
  Builds the JSON-RPC response to a request the server sent.

  Only `ping` is ever answered with a result: lemieux declares no capability a
  server may call back into, and an unknown method gets the standard
  "method not found" error rather than silence, because a server waiting on an
  answer that never comes is a server that hangs.
  """
  @spec response(id :: term(), result :: map()) :: map()
  def response(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  @doc "Builds the JSON-RPC error response to a request the server sent."
  @spec error_response(id :: term(), code :: integer(), message :: String.t()) :: map()
  def error_response(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}

  @doc """
  Builds a JSON-RPC notification, which has no id because nothing answers it.
  """
  @spec notification(method :: String.t(), params :: map()) :: map()
  def notification(method, params \\ %{})
  def notification(method, params) when map_size(params) == 0, do: base_notification(method)

  def notification(method, params),
    do: method |> base_notification() |> Map.put("params", params)

  defp base_notification(method), do: %{"jsonrpc" => "2.0", "method" => method}

  @doc """
  Decides what a JSON-RPC error says about the server that sent it.

  `{:modern, versions}` for a server that recognised the request and disagreed
  about the version; `:legacy` for anything else. See the module documentation
  for why the fallback goes this way.
  """
  @spec classify(error :: map()) :: {:modern, [String.t()]} | :legacy
  def classify(%{"code" => @unsupported_version} = error) do
    {:modern, get_in(error, ["data", "supported"]) || []}
  end

  def classify(_error), do: :legacy

  @doc """
  Picks the newest revision both sides speak.
  """
  @spec choose(supported :: [String.t()]) :: {:ok, String.t()} | {:error, String.t()}
  def choose(supported) when is_list(supported) do
    case Enum.find(@versions, &(&1 in supported)) do
      nil ->
        {:error,
         "no protocol version in common: the server speaks #{inspect(supported)}, " <>
           "lemieux speaks #{inspect(@versions)}"}

      version ->
        {:ok, version}
    end
  end

  @doc """
  Reads a `tools/list` result into remote tools and a cursor for the next page.
  """
  @spec tools(result :: map(), server :: String.t(), opts :: keyword()) ::
          {:ok, [RemoteTool.t()], String.t() | nil}
  def tools(result, server \\ "server", opts \\ []) do
    {:ok, tools, cursor, _problems} = tools_report(result, server, opts)
    {:ok, tools, cursor}
  end

  @doc """
  As `tools/3`, and also says why each left-out tool was left out.

  The sentences name the server and the tool, so a host can show them where
  it shows the rest of a server's state instead of leaving somebody to wonder
  why a tool the server's documentation promises never appears.
  """
  @spec tools_report(result :: map(), server :: String.t(), opts :: keyword()) ::
          {:ok, [RemoteTool.t()], String.t() | nil, [String.t()]}
  def tools_report(result, server \\ "server", opts \\ []) do
    {tools, problems} =
      result
      |> Map.get("tools", [])
      |> List.wrap()
      |> Enum.reduce({[], []}, fn raw, {tools, problems} ->
        case tool(raw, server, opts) do
          {:ok, tool} -> {[tool | tools], problems}
          {:error, problem} -> {tools, [problem | problems]}
        end
      end)

    {:ok, Enum.reverse(tools), Map.get(result, "nextCursor"), Enum.reverse(problems)}
  end

  # A tool with no schema cannot be described to a model, and offering it
  # anyway produces calls the server rejects. Dropping one tool is better than
  # failing the whole list, which would cost every other tool on the server —
  # and a schema that is not an object is refused by every provider, and by
  # `Lemieux.Tool.validate_all/1`, which would drop the whole MCP catalog.
  defp tool(%{"name" => name, "inputSchema" => schema} = tool, server, opts)
       when is_binary(name) and is_map(schema) do
    with {:ok, schema} <- input_schema(schema, server, name) do
      output_schema = Map.get(tool, "outputSchema")

      {:ok,
       %RemoteTool{
         name: name,
         server: server,
         title: Map.get(tool, "title"),
         # A tool with no description still has a name, and a name is a worse
         # description than none is a broken one.
         description: description(Map.get(tool, "description"), name),
         schema: schema,
         output_schema: if(is_map(output_schema), do: output_schema),
         annotations: json_map(Map.get(tool, "annotations")),
         meta: json_map(Map.get(tool, "_meta")),
         protocol_version: Keyword.get(opts, :protocol_version),
         server_info: Keyword.get(opts, :server_info),
         content_types: content_types(output_schema)
       }}
    end
  end

  defp tool(%{"name" => name}, server, _opts) when is_binary(name),
    do: {:error, "The MCP tool #{inspect(name)} from #{server} has no input schema; left out."}

  defp tool(_tool, server, _opts),
    do: {:error, "#{server} listed a tool with no name; left out."}

  # The specification requires an object schema. A server that leaves out
  # `"type"` means one; a server that names another type has written something
  # no provider accepts as a tool's parameters.
  defp input_schema(%{"type" => "object"} = schema, _server, _name), do: {:ok, schema}

  defp input_schema(schema, _server, _name) when not is_map_key(schema, "type"),
    do: {:ok, Map.put(schema, "type", "object")}

  defp input_schema(%{"type" => type}, server, name),
    do:
      {:error,
       "The MCP tool #{inspect(name)} from #{server} takes #{inspect(type)} rather than an " <>
         "object of arguments; left out."}

  defp description(text, _name) when is_binary(text) and text != "", do: text
  defp description(_text, name), do: name

  @doc """
  Reads a `prompts/list` result into prompts and a cursor for the next page.

  Each prompt keeps the server's own shape — `"name"`, and optionally
  `"title"`, `"description"` and `"arguments"` — because a host renders it and
  hands the name back to `prompts/get` unchanged. An entry with no name is left
  out: nothing could ever ask for it.
  """
  @spec prompts(result :: map()) :: {:ok, [map()], String.t() | nil}
  def prompts(result) when is_map(result) do
    prompts =
      result
      |> Map.get("prompts", [])
      |> List.wrap()
      |> Enum.filter(&match?(%{"name" => name} when is_binary(name), &1))
      |> Enum.map(fn prompt ->
        Map.update(prompt, "arguments", [], fn arguments ->
          arguments
          |> List.wrap()
          |> Enum.filter(&match?(%{"name" => name} when is_binary(name), &1))
        end)
      end)

    {:ok, prompts, Map.get(result, "nextCursor")}
  end

  @doc """
  Flattens a `prompts/get` result into the text a person would send.

  A prompt is a list of messages, and a slash command sends one prompt, so the
  messages are joined in order. Content lemieux cannot put in a prompt —
  an image, audio — is named rather than dropped, for the same reason a tool's
  is: a message that silently lost part of itself says something different.
  """
  @spec prompt_text(result :: map()) :: String.t()
  def prompt_text(result) when is_map(result) do
    result
    |> Map.get("messages", [])
    |> List.wrap()
    |> Enum.map(fn message -> message |> Map.get("content") |> List.wrap() end)
    |> Enum.map_join("\n\n", fn blocks ->
      blocks
      |> Enum.map(&content/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
    end)
    |> String.trim()
  end

  @doc """
  Reads a `resources/list` result into resources and a cursor for the next page.

  Resources without a `"uri"` are left out, since `resources/read` needs one.
  """
  @spec resources(result :: map()) :: {:ok, [map()], String.t() | nil}
  def resources(result) when is_map(result) do
    resources =
      result
      |> Map.get("resources", [])
      |> List.wrap()
      |> Enum.filter(&match?(%{"uri" => uri} when is_binary(uri), &1))

    {:ok, resources, Map.get(result, "nextCursor")}
  end

  @doc """
  Flattens a `resources/read` result into text, naming what cannot be shown.

  A resource with binary contents (`"blob"`) is described by its URI and MIME
  type rather than decoded into the prompt: base64 is not something a model
  reads, and an image belongs to the host's attachment handling.
  """
  @spec resource_text(result :: map()) :: String.t()
  def resource_text(result) when is_map(result) do
    result
    |> Map.get("contents", [])
    |> List.wrap()
    |> Enum.map_join("\n\n", fn
      %{"text" => text} when is_binary(text) ->
        text

      %{"uri" => uri} = blob ->
        "[#{Map.get(blob, "mimeType", "binary")} content at #{uri}, which lemieux cannot show you]"

      _other ->
        ""
    end)
    |> String.trim()
  end

  @doc """
  Reads a `tools/call` result into the output a model reads.

  `{:input_required, requests, state}` is a server saying it needs something
  before it can answer — see `Lemieux.MCP.Elicitation`. The caller satisfies
  what it can and retries with the answers and the state echoed back
  untouched.

  `{:error, _}` is a *tool execution* error — the specification is explicit
  that these should reach the model, because they are what it needs to correct
  itself — not a failure of the call.
  """
  @spec output(result :: map()) ::
          {:ok, Result.t()}
          | {:error, Result.t()}
          | {:input_required, map(), String.t() | nil}
  def output(%{"resultType" => "input_required"} = result) do
    {:input_required, Map.get(result, "inputRequests", %{}), Map.get(result, "requestState")}
  end

  def output(result) do
    {blocks, texts, attachments} =
      result
      |> Map.get("content", [])
      |> Enum.filter(&is_map/1)
      |> Enum.map(&block/1)
      |> unzip3()

    text =
      texts
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("\n")
      |> fallback(result)

    structured = Map.get(result, "structuredContent")

    tool_result =
      Result.new(text,
        structured_content: structured,
        content: blocks,
        metadata: json_map(Map.get(result, "_meta")),
        attachments: Enum.concat(attachments)
      )

    if Map.get(result, "isError", false), do: {:error, tool_result}, else: {:ok, tool_result}
  end

  # One content block read three ways at once: the block the audit record
  # keeps, the text the model reads, and what is attached beside that text.
  #
  # An image or a PDF becomes a `Lemieux.Tool.Attachment` here, where the
  # block is read, rather than being written into the text as "cannot be
  # shown" and replaced later. The replacement had to find the sentence by
  # its exact wording, so rewording it would have silently stopped images
  # from reaching the model. Content that still cannot be sent (an
  # unsupported type, base64 that does not decode) keeps its block and its
  # sentence.
  defp block(block) do
    case attachment(block) do
      {:ok, attachment, record} -> {record, "[#{label(attachment)}]", [attachment]}
      :none -> {block, content(block), []}
    end
  end

  defp unzip3(triples) do
    {blocks, texts, attachments} =
      Enum.reduce(triples, {[], [], []}, fn {block, text, attached}, {blocks, texts, all} ->
        {[block | blocks], [text | texts], [attached | all]}
      end)

    {Enum.reverse(blocks), Enum.reverse(texts), Enum.reverse(attachments)}
  end

  # A screenshot arrives as `{"type": "image", "data": base64, "mimeType": ...}`
  # and a document as an embedded resource with a `"blob"`. Left as content
  # blocks they reached no model — a provider is sent a result's text — and a
  # large one blew the audit budget, taking the rest of the structured result
  # with it. As attachments they are sent to a model that can read them and
  # bounded by the attachment limits; the audit record keeps each block's
  # type, media type and size, not its bytes.
  defp attachment(%{"type" => "image", "data" => data, "mimeType" => media_type} = block)
       when is_binary(data) and is_binary(media_type) do
    with true <- Attachment.image_type?(media_type),
         {:ok, bytes} <- Base.decode64(data, ignore: :whitespace) do
      attachment = Attachment.new(:image, media_type, bytes)
      {:ok, attachment, recorded(block, "data", attachment)}
    else
      _unsendable -> :none
    end
  end

  defp attachment(
         %{
           "type" => "resource",
           "resource" => %{"blob" => blob, "mimeType" => media_type} = resource
         } = block
       )
       when is_binary(blob) and is_binary(media_type) do
    with {:ok, kind} <- resource_kind(media_type),
         {:ok, bytes} <- Base.decode64(blob, ignore: :whitespace) do
      path = resource |> Map.get("uri", "") |> to_string() |> URI.parse() |> uri_name()
      attachment = Attachment.new(kind, media_type, bytes, path: path)
      {:ok, attachment, Map.put(block, "resource", recorded(resource, "blob", attachment))}
    else
      _unsendable -> :none
    end
  end

  defp attachment(_block), do: :none

  defp resource_kind(media_type) do
    cond do
      Attachment.image_type?(media_type) -> {:ok, :image}
      Attachment.document_type?(media_type) -> {:ok, :document}
      true -> :none
    end
  end

  defp uri_name(%URI{path: path}) when is_binary(path) and path != "", do: Path.basename(path)
  defp uri_name(_uri), do: ""

  # The audit record of a block that became an attachment: everything it said
  # except the bytes, which live once, in the attachment.
  defp recorded(map, bytes_key, attachment) do
    map
    |> Map.delete(bytes_key)
    |> Map.put("size", Attachment.size(attachment))
    |> Map.put("attached", true)
  end

  defp label(%{"kind" => "document", "path" => path} = attachment) when path != "",
    do: "document: #{path} (#{Attachment.describe(attachment)})"

  defp label(%{"kind" => kind} = attachment), do: "#{kind}: #{Attachment.describe(attachment)}"

  defp content(%{"type" => "text", "text" => text}) when is_binary(text), do: text

  defp content(%{"type" => "resource", "resource" => %{"text" => text}}) when is_binary(text),
    do: text

  defp content(%{"type" => "resource_link", "uri" => uri} = link),
    do: "[#{Map.get(link, "name", "resource")}: #{uri}]"

  # Not dropped: a model told nothing came back would conclude the tool did
  # nothing, when in fact it returned something this client cannot render.
  defp content(%{"type" => type}), do: "[#{type} content, which lemieux cannot show you]"
  defp content(_block), do: ""

  defp fallback("", result) do
    case Map.get(result, "structuredContent") do
      nil -> "(the tool returned no output)"
      structured -> JSON.encode!(structured)
    end
  end

  defp fallback(text, _result), do: text

  defp content_types(output_schema) when is_map(output_schema),
    do: ["text/plain", "application/json"]

  defp content_types(_output_schema), do: ["text/plain"]

  defp json_map(value) when is_map(value), do: value
  defp json_map(_value), do: %{}
end
