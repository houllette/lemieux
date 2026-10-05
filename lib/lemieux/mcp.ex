defmodule Lemieux.MCP do
  @moduledoc """
  Attaching MCP servers to a session.

  A session is given `:mcp_servers` — a list of configurations — and gets the
  tools those servers offer, named for the server they came from. From there
  nothing is special: a remote tool goes through the same dispatch, the same
  `before_tool_call` hook, the same approval, the same transcript entry and
  the same error handling as `read` or `bash`. That sameness is the whole
  design. A tool a host cannot write a policy for is a hole in the policy.

  ## Configuration

  JSON-shaped, because it is persisted in the transcript and usually comes
  from a file somebody wrote:

      %{"name" => "github", "transport" => "stdio",
        "command" => "npx", "args" => ["-y", "@modelcontextprotocol/server-github"],
        "env" => %{"GITHUB_TOKEN" => "..."}}

      %{"name" => "docs", "transport" => "http", "url" => "https://example.com/mcp",
        "headers" => %{"authorization" => "Bearer ..."}}

  Atom keys are accepted and normalised, because writing them by hand in
  Elixir is otherwise miserable.

  ## Transports are looked up by name

  `"transport"` names an entry in `transports/0` — `stdio` and `http` are
  built in — and a host adds one by passing `transports: %{"name" => Module}`
  to `connect/2`, where `Module` implements `Lemieux.MCP.Transport`. The
  host's map is merged over the built-in one, so it can also replace a
  built-in. A session carries the map as its `:mcp_transports` option and
  hands it to `connect/2` unchanged; it is neither recorded nor restored,
  because a module name is only meaningful in a host that has the module.

  The name is the configuration's; whether it exists is the registry's to
  decide, at connect time. `Lemieux.MCP.Config` passes a name it has never
  heard of straight through rather than refusing it, since a file cannot know
  what the host registered. A name nobody registered costs that server its
  tools, like any other server that will not start, and the log names the
  transports that were known.

  ## A server that will not start

  Costs its own tools and nothing else. The session starts, the rest of its
  tools work, and the failure is logged rather than raised: an agent that
  cannot reach one of four servers should do what it can with the other
  three, and a session that refuses to start because a subprocess is missing
  is a worse answer than one that says so and carries on.

  ## Where a configuration came from

  A configuration may carry `"source"`: `"project"` for one read from a
  repository's `.mcp.json` (`"trusted"` once a person has trusted it),
  `"personal"` for one a person keeps in their own settings, `"explicit"` for a
  file named on a command line, `"plugin"` for one a selected plugin declares.
  It matters for one thing: a project's configuration is not allowed to read credential-shaped
  variables out of the environment — see `expand/2` — because the repository
  is not the person, and `${OPENAI_API_KEY}` in a header of a server somebody
  else's checkout names is a key sent to that server.
  """

  require Logger

  alias Lemieux.Environment.Credentials
  alias Lemieux.MCP.Client
  alias Lemieux.MCP.Elicitation
  alias Lemieux.MCP.Protocol
  alias Lemieux.MCP.RemoteTool
  alias Lemieux.MCP.Transport
  alias Lemieux.Session
  alias Lemieux.Supervisor, as: Sup

  # Claude Code's `"type"` values, and what each means here. `"sse"` is kept as
  # written so the refusal can say what it is; see `transport/2`.
  @types %{
    "stdio" => "stdio",
    "http" => "http",
    "streamable-http" => "http",
    "streamable_http" => "http",
    "sse" => "sse"
  }

  @doc """
  Normalises a server configuration into the JSON shape that is persisted.

  The transport is `"transport"` when given — lemieux's own key, and the one
  that wins — else what Claude Code's `"type"` names (`stdio`, `http`, or the
  legacy `sse`), else inferred: a `"url"` means HTTP, anything else stdio.
  """
  @spec config(config :: map()) :: map()
  def config(config) when is_map(config) do
    config
    |> Map.new(fn {key, value} -> {to_string(key), normalise(value)} end)
    |> Map.put_new("name", "mcp")
    |> then(&Map.put_new_lazy(&1, "transport", fn -> infer_transport(&1) end))
    |> Map.update!("name", &to_string/1)
    |> Map.update!("transport", &to_string/1)
  end

  defp infer_transport(%{"type" => type}) when is_binary(type),
    do: Map.get(@types, String.downcase(type), type)

  defp infer_transport(%{"url" => _url}), do: "http"
  defp infer_transport(_config), do: "stdio"

  defp normalise(value) when is_map(value),
    do: Map.new(value, fn {key, inner} -> {to_string(key), inner} end)

  defp normalise(value) when is_list(value), do: Enum.map(value, &to_string/1)
  defp normalise(value), do: value

  @doc """
  The transports a configuration may name, by name.

  What `connect/2` starts from before merging the host's `:transports` over
  it. A host's map need not repeat these; it is public so a host can see what
  is built in, and so a configuration can be checked against the names that
  will be known before a session is started with it.
  """
  @spec transports() :: %{String.t() => module()}
  def transports, do: %{"stdio" => Transport.Stdio, "http" => Transport.HTTP}

  @doc """
  Starts a client for each configuration and returns the tools they offer.

  Returns the tools, already bound to the client that serves them, and the
  clients themselves so a caller can stop them. A configuration that cannot
  be connected contributes no tools and does not stop the others.

  ## Options

    * `:supervisor` — required, the runtime the clients start under.
    * `:owner` — a process the clients follow; when it goes, so do they.
      Change notifications (a server's tool list changing) are sent to it;
      see `Lemieux.MCP.Client`.
    * `:transports` — a map of transport name to module, merged over
      `transports/0`. Atom keys are accepted, as in a configuration.
    * `:interactive_auth` — `false` to report a server whose OAuth needs a
      browser as `{:needs_auth, info}` instead of opening one and waiting.
      See `connect_server/2`.
    * `:credentials` — what a stdio server may inherit from this VM's
      environment, as a `Lemieux.Environment.Credentials` policy. Inherits
      everything by default.
    * `:allow_env` — credential-shaped variable names (or `*` globs) a
      project-sourced configuration may nevertheless read; see `expand/2`.
    * `:cwd`, `:auth`, `:stdio_launcher` — read by the built-in transports;
      the whole list is passed to every transport's `configure/2`, so a host's
      transport may add its own.

  ## Per-server budgets

  A configuration may carry, in milliseconds, `"startup_timeout"` (the
  handshake and first listing; 60s by default), `"timeout"` (every other
  request, and the default for tool calls) and `"tool_timeout"` (how long a
  tool call may go without answering or reporting progress; 10 minutes by
  default). See `Lemieux.MCP.Client` for why a tool call's clock is silence
  rather than total time.
  """
  @spec connect(configs :: [map()], opts :: keyword()) :: {[struct()], [pid()]}
  def connect(configs, opts) do
    {tools, clients, _errors} = connect_report(configs, opts)
    {tools, clients}
  end

  @doc """
  Connects servers and returns connection failures by server name.

  A failure is a sentence, except for a server that needs somebody to sign in
  when `interactive_auth: false` was given: that one is `{:needs_auth, info}`,
  with the shape `connect_server/2` documents, so a host can offer to finish
  the flow rather than only print that it did not happen.

  The tools of all the servers are named together — see
  `disambiguate/1` — so two servers whose names collide once made valid for a
  provider still offer distinct tools.
  """
  @spec connect_report(configs :: [map()], opts :: keyword()) ::
          {[struct()], [pid()], %{String.t() => String.t() | {:needs_auth, map()}}}
  def connect_report(configs, opts) do
    {tool_batches, clients, errors} =
      configs
      |> Enum.map(&connect_server(&1, opts))
      |> Enum.reduce({[], [], %{}}, fn
        {:ok, %{client: client, tools: tools}}, {batches, clients, errors} ->
          {[tools | batches], [client | clients], errors}

        {:error, %{name: name, reason: reason}}, {batches, clients, errors} ->
          {batches, clients, Map.put(errors, name, reason)}
      end)

    tools = tool_batches |> Enum.reverse() |> List.flatten() |> disambiguate()
    {tools, clients, errors}
  end

  @doc """
  Connects one server and lists its tools.

  The unit a host connects in parallel: every server is independent, so a
  session need not wait for a slow `npx` download before the others are
  usable. Returns the client, its tools (already bound to it), the notices
  from listing them — tools renamed to fit a provider, or left out — and the
  capabilities the server declared. A server offering prompts or resources but
  no tools is connected with an empty tool list; one offering none of the
  three is not.

  On failure, `reason` is a sentence, or — only when `interactive_auth: false`
  was given — `{:needs_auth, info}` for a server whose OAuth flow needs
  somebody at a browser. `info` has `:server`, `:url`, `:resource` and
  `:issuer`. The client is stopped either way; a host finishing the flow
  connects again without the option.

  Options are those of `connect/2`.
  """
  @spec connect_server(config :: map(), opts :: keyword()) ::
          {:ok,
           %{
             name: String.t(),
             client: pid(),
             tools: [RemoteTool.t()],
             notices: [String.t()],
             capabilities: map()
           }}
          | {:error, %{name: String.t(), reason: String.t() | {:needs_auth, Client.needs_auth()}}}
  def connect_server(config, opts) do
    config = config(config)
    supervisor = Keyword.fetch!(opts, :supervisor)
    name = Map.fetch!(config, "name")

    with {:ok, transport} <- transport(config, opts),
         {:ok, client} <-
           DynamicSupervisor.start_child(
             Sup.session_supervisor(supervisor),
             {Client, [server: name, transport: transport] ++ client_opts(config, opts)}
           ) do
      finish_client_start(client, name, supervisor, opts)
    else
      {:error, reason} ->
        unavailable(name, reason)
        {:error, %{name: name, reason: describe(reason)}}
    end
  end

  defp client_opts(config, opts) do
    [
      owner: Keyword.get(opts, :owner),
      timeout: budget(config, "timeout"),
      startup_timeout: budget(config, "startup_timeout"),
      tool_timeout: budget(config, "tool_timeout") || budget(config, "timeout")
    ]
  end

  # A budget is a positive integer of milliseconds; anything else is ignored
  # rather than trusted, so a stray string cannot become a zero timeout.
  defp budget(config, key) do
    case Map.get(config, key) do
      value when is_integer(value) and value > 0 -> value
      _absent -> nil
    end
  end

  defp finish_client_start(client, name, supervisor, opts) do
    case Client.list_tools(client) do
      {:ok, tools} ->
        keep_client(client, name, supervisor, tools, Client.info(client))

      {:error, reason} ->
        info = Client.info(client)
        stop_client(client, supervisor)
        failed(name, reason, info.needs_auth, Keyword.get(opts, :interactive_auth, true))
    end
  end

  # A server with no tools is still worth its connection when it declared
  # prompts or resources: those reach a person as slash commands and `@`
  # references, not through the tool catalog. One that offers none of the
  # three has nothing for anybody and is let go, as before.
  defp keep_client(client, name, supervisor, [], info) do
    if offers_beyond_tools?(info.capabilities) do
      {:ok, connected(client, name, [], info)}
    else
      stop_client(client, supervisor)
      unavailable(name, "the server offered no tools")
      {:error, %{name: name, reason: "the server offered no tools"}}
    end
  end

  defp keep_client(client, name, _supervisor, tools, info),
    do: {:ok, connected(client, name, tools, info)}

  defp connected(client, name, tools, info),
    do: %{
      name: name,
      client: client,
      tools: tools,
      notices: info.notices,
      capabilities: info.capabilities || %{}
    }

  defp offers_beyond_tools?(capabilities) when is_map(capabilities),
    do: Map.has_key?(capabilities, "prompts") or Map.has_key?(capabilities, "resources")

  defp offers_beyond_tools?(_capabilities), do: false

  defp failed(name, _reason, needs_auth, false) when is_map(needs_auth) do
    Logger.info("lemieux: the MCP server #{name} needs authorization before it can be used")
    {:error, %{name: name, reason: {:needs_auth, needs_auth}}}
  end

  defp failed(name, reason, _needs_auth, _interactive) do
    unavailable(name, reason)
    {:error, %{name: name, reason: describe(reason)}}
  end

  defp stop_client(client, supervisor),
    do: DynamicSupervisor.terminate_child(Sup.session_supervisor(supervisor), client)

  @doc """
  Makes the offered names of tools from several servers distinct.

  Each server's client already names its own tools validly
  (`Lemieux.MCP.RemoteTool.assign_names/1`); two servers can still collide —
  `my.docs` and `my_docs` both become `my_docs` once made valid. A host that
  connects servers separately calls this over the union before offering it.
  """
  @spec disambiguate(tools :: [RemoteTool.t()]) :: [RemoteTool.t()]
  def disambiguate(tools) when is_list(tools) do
    {tools, notices} = RemoteTool.assign_names(tools)
    Enum.each(notices, &Logger.debug("lemieux: #{&1}"))
    tools
  end

  defp unavailable(name, reason) do
    Logger.warning("lemieux: the MCP server #{name} is unavailable: #{describe(reason)}")
  end

  # A reason that is already a sentence is printed as one; an escaped, quoted
  # string in a log line is what somebody has to read past to find out why.
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)

  # The name is resolved here and the configuration is read by the module it
  # resolves to. Nothing in this module knows what a stdio server needs, which
  # is what lets a host's transport need something else.
  defp transport(%{"transport" => name} = config, opts) do
    registry = Map.merge(transports(), host_transports(opts))

    case Map.fetch(registry, name) do
      {:ok, module} ->
        with {:ok, transport_config} <- module.configure(config, opts),
             do: {:ok, {module, transport_config}}

      :error when name == "sse" ->
        {:error,
         ~s(#{config["name"]} uses the legacy SSE transport \("type": "sse"\), which lemieux ) <>
           "does not speak. Most servers that offered SSE also serve Streamable HTTP, usually at " <>
           ~s(/mcp instead of /sse: set "type": "http" and point "url" there.)}

      :error ->
        known = registry |> Map.keys() |> Enum.sort() |> Enum.join(", ")
        {:error, "there is no #{inspect(name)} MCP transport; the known ones are #{known}"}
    end
  end

  defp host_transports(opts) do
    Map.new(Keyword.get(opts, :transports) || %{}, fn {name, module} ->
      {to_string(name), module}
    end)
  end

  @doc """
  Replaces `${VAR}` with what the environment says, in a configuration about
  to be used.

  **Done here and not in `config/1`, which is deliberate.** A server's
  configuration is written into the transcript, and a token expanded before
  that point would be written with it — a secret on disk, in a file whose
  whole purpose is to be kept and read later. The transcript records
  `${GITHUB_TOKEN}`; only the process about to make the request ever sees what
  it stands for.

  A variable that is not set is an error naming it, rather than a request sent
  with the word `${GITHUB_TOKEN}` where a credential should be and a puzzling
  401 to show for it — unless it was written `${NAME:-default}`, Claude Code's
  spelling for a fallback, in which case the default is used.

  ## A repository's configuration does not read credentials

  With `source: "project"`, a variable whose name looks like a credential —
  it contains `KEY`, `TOKEN`, `SECRET`, `PASSWORD` or `PASSWD`, in any letter
  case, the rule of `Lemieux.Environment.Credentials` — is refused unless
  `:allow_env` names it.
  A checkout's `.mcp.json` asking for `${ANTHROPIC_API_KEY}` in the headers of
  a server of its choosing would otherwise send the key there the moment the
  repository was opened. A person who has looked at which variables the file
  reads and trusted it passes them in `:allow_env`
  (`Lemieux.MCP.Trust.allowed_env/3` keeps that list).
  """
  @spec expand(value :: term(), opts :: keyword()) :: {:ok, term()} | {:error, String.t()}
  def expand(value, opts \\ [])

  def expand(value, opts) when is_binary(value) do
    ~r/\$\{([A-Za-z_][A-Za-z0-9_]*)(?::-([^}]*))?\}/
    |> Regex.scan(value)
    |> Enum.reduce_while({:ok, value}, fn match, {:ok, acc} ->
      case variable(match, opts) do
        {:ok, whole, replacement} -> {:cont, {:ok, String.replace(acc, whole, replacement)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def expand(value, opts) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case expand(item, opts) do
        {:ok, expanded} -> {:cont, {:ok, [expanded | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, expanded} -> {:ok, Enum.reverse(expanded)}
      {:error, reason} -> {:error, reason}
    end
  end

  def expand(value, opts) when is_map(value) do
    Enum.reduce_while(value, {:ok, %{}}, fn {key, item}, {:ok, acc} ->
      case expand(item, opts) do
        {:ok, expanded} -> {:cont, {:ok, Map.put(acc, key, expanded)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def expand(value, _opts), do: {:ok, value}

  defp variable([whole, name | default], opts) do
    cond do
      withheld?(name, opts) ->
        {:error,
         "a project MCP configuration asks for ${#{name}}, and lemieux does not hand " <>
           "credential-shaped variables to a repository's servers unless they are allowed. " <>
           "Review the repository's MCP servers and trust them, or move this server to your " <>
           "own configuration."}

      value = System.get_env(name) ->
        {:ok, whole, value}

      default != [] ->
        {:ok, whole, hd(default)}

      true ->
        {:error, "#{name} is not set, and an MCP server configuration wants it"}
    end
  end

  defp withheld?(name, opts) do
    Keyword.get(opts, :source) == "project" and
      Credentials.sensitive?(name, {:scrub, Keyword.get(opts, :allow_env, [])})
  end

  @doc """
  The expansion options for one server's configuration: where it came from,
  and what the host allowed. What a transport passes to `expand/2`.
  """
  @spec expansion(config :: map(), opts :: keyword()) :: keyword()
  def expansion(config, opts) when is_map(config) do
    source =
      case Map.get(config, "source") do
        nil -> nil
        source -> to_string(source)
      end

    [source: source, allow_env: Keyword.get(opts, :allow_env) || []]
  end

  # ---------------------------------------------------------------------------
  # Prompts and resources
  # ---------------------------------------------------------------------------

  @doc """
  The prompts one server offers. See `Lemieux.MCP.Client.list_prompts/1`.
  """
  @spec list_prompts(client :: pid()) :: {:ok, [map()]} | {:error, String.t()}
  def list_prompts(client), do: Client.list_prompts(client)

  @doc """
  One prompt, filled in and flattened into the text a person would send.

  What a host's slash command sends in place of the command.
  """
  @spec prompt(client :: pid(), name :: String.t(), arguments :: map()) ::
          {:ok, String.t()} | {:error, String.t()}
  def prompt(client, name, arguments \\ %{}) do
    with {:ok, result} <- Client.get_prompt(client, name, arguments),
         do: {:ok, Protocol.prompt_text(result)}
  end

  @doc """
  The name a host offers a prompt under as a slash command:
  `mcp__server__prompt`, made valid the same way a tool name is.
  """
  @spec prompt_command(server :: String.t(), prompt :: String.t()) :: String.t()
  def prompt_command(server, prompt),
    do: "mcp" <> RemoteTool.separator() <> RemoteTool.qualify(server, prompt)

  @doc """
  The resources one server offers. See `Lemieux.MCP.Client.list_resources/1`.
  """
  @spec list_resources(client :: pid()) :: {:ok, [map()]} | {:error, String.t()}
  def list_resources(client), do: Client.list_resources(client)

  @doc """
  One resource's contents as text, for a host attaching it to a prompt the way
  it attaches a file. Binary contents are named rather than decoded.
  """
  @spec resource(client :: pid(), uri :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def resource(client, uri) do
    with {:ok, result} <- Client.read_resource(client, uri),
         do: {:ok, Protocol.resource_text(result)}
  end

  @rounds 3

  @doc """
  Calls a remote tool, answering anything the server asks for on the way.

  A server may reply that it needs input before it can finish rather than
  answering. What it asks for is put to whoever is attached to the session —
  the same asking `Lemieux.Tools.AskUser` does — and the call is retried with
  the answers and the server's opaque state echoed back untouched.

  Bounded at #{@rounds} rounds. A server is entitled to keep asking, and a
  client that kept answering would be an unbounded loop with a person at the
  end of it.
  """
  @spec call_tool(tool :: RemoteTool.t(), args :: map(), context :: map()) ::
          {:ok, Lemieux.Tool.Result.t()} | {:error, Lemieux.Tool.Result.t() | String.t()}
  def call_tool(tool, args, context), do: call_tool(tool, args, context, %{}, @rounds)

  defp call_tool(tool, _args, _context, _extra, 0) do
    {:error,
     "the #{tool.server} server asked for more input #{@rounds} times without ever " <>
       "answering; giving up on this call"}
  end

  defp call_tool(tool, args, context, extra, rounds) do
    case Client.call_tool(tool.client, tool.name, args, extra) do
      {:input_required, requests, request_state} ->
        retry(tool, args, context, requests, request_state, rounds)

      answer ->
        answer
    end
  end

  defp retry(tool, args, context, requests, request_state, rounds) do
    responses =
      Map.new(requests, fn {key, request} -> {key, answer(tool, context, key, request)} end)

    extra =
      %{}
      |> put_present("inputResponses", responses)
      |> put_present("requestState", request_state)

    call_tool(tool, args, context, extra, rounds - 1)
  end

  # A retry must not carry either field unless the server sent one: an empty
  # `inputResponses` says nothing, and inventing a `requestState` is exactly
  # what the specification forbids.
  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, value) when value == %{}, do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp answer(tool, context, key, request) do
    case Elicitation.question(request, tool.server) do
      {:ok, question} ->
        Elicitation.response(request, ask(context, key, question, request))

      :unsupported ->
        Logger.warning(
          "lemieux: the MCP server #{tool.server} asked for input of a kind lemieux " <>
            "did not declare (#{inspect(Map.get(request, "method"))}); declining"
        )

        Elicitation.declined()
    end
  end

  defp ask(context, key, question, request) do
    # Keyed by the call and the server's own identifier for the request, so
    # two questions inside one tool call do not collide in the session's
    # parked table. The title and fields ride beside the sentence so a host
    # can show what was asked, field by field, rather than only the sentence.
    id = "#{context.call_id}:#{key}"

    Session.park(context.session, id, :question, %{
      call_id: id,
      question: question,
      title: Elicitation.title(request),
      fields: Elicitation.fields(request)
    })
  end

  @doc """
  Stops clients started by `connect/2`.
  """
  @spec disconnect(clients :: [pid()], supervisor :: atom()) :: :ok
  def disconnect(clients, supervisor) do
    Enum.each(clients, fn client ->
      DynamicSupervisor.terminate_child(Sup.session_supervisor(supervisor), client)
    end)
  end
end
