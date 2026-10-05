defmodule Lemieux.Extensions.A2A do
  @moduledoc """
  Opt-in peer communication. The host supplies a fixed peer allowlist and
  equips ask_agent plus /a2a. Neither transcripts nor model arguments can
  choose endpoints or credentials. Peer calls disclose their input and can
  spend money on the remote host; the tool is external, never read-only.
  """
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]
  alias Lemieux.A2A.Message
  alias Lemieux.A2A.PeerTool
  alias Lemieux.A2A.Transport.HTTP
  alias Lemieux.Harness

  @impl Lemieux.Extension
  @spec init(opts :: keyword()) :: {:ok, map()} | {:error, term()}
  def init(opts) do
    peers = Keyword.get(opts, :peers, %{})

    with :ok <- validate(peers) do
      state = %{
        peers: peers,
        max_calls: Keyword.get(opts, :max_calls, 8),
        timeout: Keyword.get(opts, :timeout, 60_000)
      }

      {:ok,
       Map.merge(state, %{tool: PeerTool.new(state), commands: Keyword.get(opts, :commands, [])})}
    end
  end

  @impl Lemieux.Extension
  def apply(harness, state) do
    tool = state.tool

    harness =
      Harness.update_tools(harness, fn tools ->
        Enum.reject(tools, &(Lemieux.Tool.name(&1) == "ask_agent")) ++ [tool]
      end)

    %{harness | commands: Enum.uniq(harness.commands ++ state.commands)}
  end

  @impl Lemieux.Extension
  def describe(state),
    do: %{
      "peers" => Map.keys(state.peers) |> Enum.sort(),
      "max_calls" => state.max_calls,
      "timeout_ms" => state.timeout
    }

  @doc "Validates JSON peer configuration without resolving secrets or making requests."
  @spec validate(peers :: term()) :: :ok | {:error, String.t()}
  def validate(peers) when is_map(peers) and map_size(peers) <= 32 do
    if Enum.all?(peers, fn {name, peer} ->
         is_binary(name) and Regex.match?(~r/\A[a-zA-Z0-9_-]{1,64}\z/, name) and valid_peer?(peer)
       end),
       do: :ok,
       else: {:error, "invalid A2A peer: use a name, http(s) url, and optional bearer_env"}
  end

  def validate(_peers),
    do: {:error, "a2a_peers must be an object with at most 32 configured peers"}

  defp valid_peer?(%{"url" => url} = peer) do
    Enum.all?(Map.keys(peer), &(&1 in ["url", "bearer_env"])) and
      HTTP.valid_url?(url) and
      Message.optional?(
        peer,
        "bearer_env",
        &(is_binary(&1) and Regex.match?(~r/\A[A-Z_][A-Z0-9_]*\z/, &1))
      )
  end

  defp valid_peer?(_peer), do: false
end
