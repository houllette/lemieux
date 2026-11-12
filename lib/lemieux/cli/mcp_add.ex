defmodule Lemieux.CLI.MCPAdd do
  @moduledoc """
  Terminal MCP setup. Scope is explicit; saving alone starts no subprocess.
  Descriptors use the questionnaire's validation and secret-reference rules,
  and the existing atomic config writers. A replacement is always explicit.
  """
  alias Lemieux.CLI.Config
  alias Lemieux.CLI.Runtime
  alias Lemieux.CLI.Sanitize
  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.MCP
  alias Lemieux.MCP.Config, as: MCPConfig
  alias Lemieux.TUI.MCPForm

  @doc false
  @spec run(
          args :: list(),
          parsed :: keyword(),
          options :: struct(),
          cwd :: Path.t(),
          opts :: keyword()
        ) :: :ok | {:error, 1}
  def run(args, parsed, options, cwd, opts) do
    with {:ok, scope} <- scope(parsed),
         {:ok, server} <- descriptor(args, parsed),
         {:ok, path} <- destination(scope, options, cwd),
         :ok <- duplicate(scope, path, server["name"], parsed[:replace]),
         {saved, secrets} = MCPForm.withheld(server),
         :ok <- save(scope, path, saved) do
      IO.puts("Saved MCP server #{server["name"]} (#{scope}) to #{shown(path)}.")

      if secrets != [],
        do:
          IO.puts(
            "Secrets saved as references; export " <>
              Enum.map_join(secrets, ", ", &elem(&1, 0)) <> " before connecting."
          )

      if scope == "local",
        do:
          IO.puts(
            "Repository servers follow the existing trust prompt; personal servers of the same name take precedence."
          )

      finish_setup(server, parsed, options, cwd, opts, secrets)
    else
      {:error, message} ->
        IO.puts(:stderr, "lmx: #{shown(message)}")
        {:error, 1}
    end
  end

  defp finish_setup(server, parsed, options, cwd, opts, secrets) do
    if parsed[:non_interactive] || not Sanitize.terminal?(:stdio, opts[:interactive?]) do
      IO.puts(
        "Configuration saved; connection not attempted. Open /mcp in the TUI, select #{server["name"]}, and press r to connect/sign in."
      )

      :ok
    else
      interactive_setup(server, options, cwd, opts, secrets)
    end
  end

  defp interactive_setup(server, options, cwd, opts, secrets) do
    with {:ok, runtime} <- Runtime.mount(opts) do
      connect_opts = [
        supervisor: runtime,
        owner: self(),
        cwd: cwd,
        auth: Keyword.get_lazy(opts, :mcp_auth, fn -> Runtime.auth(options) end),
        interactive_auth: true,
        credentials: {:scrub, []}
      ]

      result =
        MCP.connect_server(
          server,
          Keyword.merge(connect_opts, Keyword.get(opts, :mcp_connect_opts, []))
        )

      setup_result(result, server, runtime, secrets)
    end
  end

  defp setup_result({:ok, %{tools: tools, client: client}}, server, runtime, _secrets) do
    MCP.disconnect([client], runtime)
    IO.puts("#{server["name"]} connected and ready with #{length(tools)} tools.")
    :ok
  end

  defp setup_result({:error, %{reason: reason}}, server, _runtime, secrets) do
    # The saved configuration survives cancelled/failed sign-in. Never repeat
    # values supplied as credentials in a setup error.
    message = if is_binary(reason), do: reason, else: "sign-in required"

    message =
      Enum.reduce(secrets, message, fn {_key, value}, text ->
        String.replace(text, value, "[withheld]")
      end)

    IO.puts(
      :stderr,
      "lmx: Configuration saved; #{server["name"]} connection failed: #{shown(message)}. Retry with /mcp, select #{server["name"]}, press r."
    )

    {:error, 1}
  end

  defp scope(parsed) do
    cond do
      parsed[:local] -> {:ok, "local"}
      parsed[:global] -> {:ok, "global"}
      true -> {:error, "mcp add requires --local or --global"}
    end
  end

  defp descriptor([name | args], parsed) do
    with {:ok, name} <- MCPForm.text_answer("name", name),
         {:ok, env} <- pairs(parsed, :env),
         {:ok, headers} <- pairs(parsed, :header) do
      transport = parsed[:transport] || if(match?(["--" | _], args), do: "stdio", else: "http")
      descriptor(transport, name, args, env, headers)
    end
  end

  defp descriptor([], _parsed),
    do: {:error, "mcp add requires a server name and URL or -- COMMAND [ARGS]"}

  defp descriptor("http", name, [url], env, headers) when map_size(env) == 0 do
    with {:ok, url} <- MCPForm.text_answer("url", url),
         do: {:ok, %{"name" => name, "transport" => "http", "url" => url, "headers" => headers}}
  end

  defp descriptor("stdio", name, ["--", command | args], env, headers)
       when map_size(headers) == 0 do
    with {:ok, command} <- MCPForm.text_answer("command", command),
         do:
           {:ok,
            %{
              "name" => name,
              "transport" => "stdio",
              "command" => command,
              "args" => args,
              "env" => env
            }}
  end

  defp descriptor(_transport, _name, _args, _env, _headers),
    do:
      {:error,
       "use --transport http NAME URL [--header NAME=VALUE], or NAME [--env NAME=VALUE] -- COMMAND [ARGS]"}

  defp pairs(parsed, key) do
    Enum.reduce_while(Keyword.get_values(parsed, key), {:ok, %{}}, fn pair, {:ok, values} ->
      case String.split(pair, "=", parts: 2) do
        [name, value] when name != "" -> {:cont, {:ok, Map.put(values, name, value)}}
        _invalid -> {:halt, {:error, "--#{key} expects NAME=VALUE"}}
      end
    end)
  end

  defp destination("local", _options, cwd), do: {:ok, Discovery.project_mcp_path(cwd)}

  defp destination("global", options, _cwd) do
    case Config.path(options.config) do
      nil -> {:error, "--global requires a personal config file; --config none has none"}
      path -> {:ok, path}
    end
  end

  defp duplicate(_scope, _path, _name, true), do: :ok

  defp duplicate(scope, path, name, _replace) do
    with {:ok, names} <- existing(scope, path) do
      if name in names,
        do: {:error, "#{name} already exists in #{path}; use --replace to replace it"},
        else: :ok
    end
  end

  defp existing("local", path) do
    if File.exists?(path) do
      with {:ok, servers} <- MCPConfig.read(path), do: {:ok, Enum.map(servers, & &1["name"])}
    else
      {:ok, []}
    end
  end

  defp existing("global", path) do
    with {:ok, config} <- Config.load(path),
         do: {:ok, Map.keys(Map.get(config.settings, "mcp_servers", %{}))}
  end

  defp save("local", path, server), do: MCPConfig.put_server(path, server)
  defp save("global", path, server), do: Config.put_mcp_server(path, server)
  defp shown(text), do: Sanitize.visible(text)
end
