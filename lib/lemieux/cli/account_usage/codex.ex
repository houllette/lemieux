defmodule Lemieux.CLI.AccountUsage.Codex do
  @moduledoc """
  Reads subscription quotas through Codex's documented account RPC only.

  This is a host reporting helper, never the Lemieux agent loop. A temporary
  empty home and working directory prevent project/config loading. External
  token mode receives only the existing access token over stdin, so the helper
  cannot refresh or overwrite the user's sign-in. The only requests are
  initialize, externally managed authentication and account/rateLimits/read.
  No thread, model turn, browser login or quota-reset operation is started.
  """
  alias Lemieux.CLI.AccountUsage
  alias Lemieux.CLI.Learning.CodexAuth
  alias Lemieux.ID
  alias Lemieux.MCP.Transport.Stdio

  @doc "Fetches read-only quotas without changing the existing sign-in."
  @spec fetch(opts :: keyword()) :: {:ok, [map()]} | {:error, String.t()}
  def fetch(opts \\ []) do
    with {:ok, credential} <- CodexAuth.credential(Keyword.get(opts, :codex_auth, [])),
         true <- is_binary(credential.account_id),
         executable when is_binary(executable) <-
           Keyword.get_lazy(opts, :codex_command, fn -> System.find_executable("codex") end) do
      isolated(executable, credential, opts)
    else
      nil ->
        {:error,
         "Codex quota reporting needs the installed Codex app-server; no model request was made."}

      _unavailable ->
        {:error,
         "A usable signed-in Codex access token and account are required. Renew the sign-in in Codex; Lemieux will not refresh it."}
    end
  end

  defp isolated(executable, credential, opts) do
    root = Path.join(System.tmp_dir!(), "lmx-usage-" <> ID.generate())

    with :ok <- File.mkdir(root), :ok <- File.chmod(root, 0o700) do
      try do
        config = %{
          "command" => executable,
          "args" => Keyword.get(opts, :codex_args, ["app-server"]),
          "name" => "Codex usage",
          "cwd" => root,
          "env" => %{"CODEX_HOME" => root, "RUST_LOG" => "off"}
        }

        with {:ok, configured} <-
               Stdio.configure(config,
                 cwd: root,
                 credentials: true,
                 stdio_limits: [
                   max_frame_bytes: 262_144,
                   max_buffer_bytes: 524_288,
                   max_total_bytes: 1_048_576
                 ]
               ),
             {:ok, connection} <- Stdio.connect(configured) do
          try do
            read_limits(connection, credential)
          after
            Stdio.close(connection)
          end
        else
          _failure ->
            {:error,
             "Codex quota reporting could not start; no credentials or raw diagnostics were retained."}
        end
      after
        File.rm_rf(root)
      end
    else
      _failure -> {:error, "Could not create a private workspace for Codex usage reporting."}
    end
  end

  defp read_limits(connection, credential) do
    initialize = %{
      "clientInfo" => %{"name" => "lemieux_usage", "title" => "Lemieux usage", "version" => "1"},
      "capabilities" => %{"experimentalApi" => true}
    }

    login = %{
      "type" => "chatgptAuthTokens",
      "accessToken" => credential.access,
      "chatgptAccountId" => credential.account_id
    }

    with {:ok, _reply, connection} <- rpc(connection, 1, "initialize", initialize),
         {:ok, connection} <- Stdio.notify(connection, %{"method" => "initialized"}),
         {:ok, _reply, connection} <- rpc(connection, 2, "account/login/start", login),
         {:ok, limits, _connection} <- rpc(connection, 3, "account/rateLimits/read", %{}) do
      normalize(limits)
    else
      _failure ->
        {:error,
         "Codex could not report subscription quotas with this access token. Refresh the sign-in in Codex or check app-server compatibility."}
    end
  end

  defp rpc(connection, id, method, params) do
    case Stdio.call(connection, %{"id" => id, "method" => method, "params" => params}, 3_000) do
      {:ok, %{"result" => result}, connection} -> {:ok, result, connection}
      _error -> :error
    end
  end

  @doc "Projects only quota windows, dropping account metadata and opaque raw fields."
  @spec normalize(limits :: map()) :: {:ok, [map()]} | {:error, String.t()}
  def normalize(limits) do
    buckets =
      case limits do
        %{"rateLimitsByLimitId" => buckets} when is_map(buckets) and map_size(buckets) > 0 ->
          buckets |> Enum.sort() |> Enum.map(&elem(&1, 1))

        %{"rateLimits" => bucket} when is_map(bucket) ->
          [bucket]

        _missing ->
          []
      end

    windows =
      buckets
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {bucket, index} ->
        Enum.flat_map(
          ["primary", "secondary"],
          &quota(bucket[&1], "quota bucket #{index} · #{&1}")
        )
      end)

    if windows == [],
      do: {:error, "Codex returned no subscription windows; remaining quota is unknown."},
      else: {:ok, windows}
  end

  defp quota(window, label) when is_map(window) do
    used =
      case window["usedPercent"] do
        value when is_number(value) and value >= 0 -> value
        _unknown -> nil
      end

    remaining = if is_number(used), do: max(100 - used, 0)

    duration = duration(window["windowDurationMins"])
    reset = reset(window["resetsAt"])

    [
      Map.put(
        AccountUsage.window(label <> " · " <> duration, "percent", used, remaining),
        :reset_at,
        reset
      )
    ]
  end

  defp quota(_unknown, _label), do: []

  defp duration(minutes) when is_integer(minutes) and minutes > 0, do: "#{minutes} minute window"
  defp duration(_unknown), do: "unknown window length"
  defp reset(seconds) when is_integer(seconds) and seconds > 0, do: seconds
  defp reset(_unknown), do: nil
end
