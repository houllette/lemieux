defmodule SecurityExample.Scope do
  @moduledoc """
  The hosts `nmap_scan` may scan, enforced as a `before_tool_call` hook.

  The model chooses the target. A system prompt that says "scan only what you
  are authorized to" is advice it can ignore, and a target it read in a file
  or a web page is a target somebody else chose. So scope is decided where the
  host decides, before the command is built: an `nmap_scan` call whose target
  is not listed is denied, and the denial is the tool result the model reads.
  Every other tool is left to the host's own policy.

  The list comes from the `:scan_targets` option, or else from the
  application environment:

      config :security_example, scan_targets: ["127.0.0.1"]

  This project's `config/config.exs` lists only the local machine. A host
  that depends on this package sets the key in its own configuration; with
  nothing configured, the list is empty and every scan is denied. Entries
  are single IPv4 addresses, like the tool's own target. A range would be
  easy to mistype into the whole of somebody else's network.

  The hook goes last among the session's hooks, after the host's own. A
  hook may rewrite a call's arguments for the hooks that follow it, so a
  scope checked first could approve a target that a later rewrite replaced.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  @typedoc "The allowed targets, as parsed IPv4 address tuples."
  @type t :: MapSet.t(:inet.ip4_address())

  @doc """
  The configured targets: the `:scan_targets` option, else the application
  environment, else none.
  """
  @spec targets(opts :: keyword()) :: [String.t()]
  def targets(opts) when is_list(opts) do
    Keyword.get_lazy(opts, :scan_targets, fn ->
      Application.get_env(:security_example, :scan_targets, [])
    end)
  end

  @doc "Parses the targets, refusing anything that is not one IPv4 address."
  @impl Lemieux.Extension
  @spec init(opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def init(opts) when is_list(opts), do: parse(targets(opts))

  @doc "Appends the scope hook after the hooks already on the harness."
  @impl Lemieux.Extension
  @spec apply(harness :: Lemieux.Harness.t(), allowed :: t()) :: Lemieux.Harness.t()
  def apply(harness, allowed), do: Lemieux.Harness.append_hooks(harness, hooks(allowed))

  @impl Lemieux.Extension
  @spec describe(allowed :: t()) :: map()
  def describe(allowed), do: %{"scan_targets" => Enum.sort(Enum.map(allowed, &format/1))}

  @doc """
  The `before_tool_call` hook for a session's `:hooks`, from parsed targets
  (`init/1`) or a list of addresses. An invalid address raises here, when
  the hook is built, rather than denying every call later.
  """
  @spec hooks(targets :: t() | [String.t()]) :: Lemieux.Hooks.t()
  def hooks(%MapSet{} = allowed), do: [before_tool_call: &decide(&1, allowed, &2)]

  def hooks(targets) do
    case parse(targets) do
      {:ok, allowed} -> hooks(allowed)
      {:error, message} -> raise ArgumentError, "security example: " <> message
    end
  end

  @doc "Allows a call unless it is an `nmap_scan` of a target outside `allowed`."
  @spec decide(call :: map(), allowed :: t(), context :: map()) :: Lemieux.Hooks.decision()
  def decide(call, allowed, context \\ %{})

  def decide(%{name: "nmap_scan", arguments: %{"target" => target}}, allowed, _context)
      when is_binary(target) do
    case address(target) do
      {:ok, address} ->
        if MapSet.member?(allowed, address), do: :allow, else: {:deny, outside(target, allowed)}

      :error ->
        {:deny, "nmap_scan needs one IPv4 address as its target, not #{inspect(target)}."}
    end
  end

  def decide(%{name: "nmap_scan"}, _allowed, _context),
    do: {:deny, "nmap_scan needs one IPv4 address as its target."}

  def decide(_call, _allowed, _context), do: :allow

  defp outside(target, allowed) do
    listed =
      case Enum.sort(Enum.map(allowed, &format/1)) do
        [] -> "No scan targets are configured"
        targets -> "The authorized targets are " <> Enum.join(targets, ", ")
      end

    "#{target} is not an authorized scan target. #{listed}. Do not scan it; report that it " <>
      "is out of scope. A person adds a target to :scan_targets in the :security_example " <>
      "configuration."
  end

  defp parse(targets) when is_list(targets) do
    Enum.reduce_while(targets, {:ok, MapSet.new()}, fn target, {:ok, allowed} ->
      case address(target) do
        {:ok, address} -> {:cont, {:ok, MapSet.put(allowed, address)}}
        :error -> {:halt, {:error, "scan target #{inspect(target)} is not one IPv4 address"}}
      end
    end)
  end

  defp parse(targets), do: {:error, "scan_targets must be a list, not #{inspect(targets)}"}

  defp address(target) when is_binary(target) do
    case :inet.parse_ipv4strict_address(String.to_charlist(target)) do
      {:ok, address} -> {:ok, address}
      {:error, _reason} -> :error
    end
  end

  defp address(_target), do: :error

  defp format(address), do: address |> :inet.ntoa() |> List.to_string()
end
