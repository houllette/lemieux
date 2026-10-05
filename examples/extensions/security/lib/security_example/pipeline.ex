defmodule SecurityExample.Pipeline do
  @moduledoc "Pure reusable preparation and policy, usable with or without an agent."

  @doc "Builds a bounded TCP-connect scan from one IPv4 address and explicit ports."
  @spec nmap_command(target :: term(), ports :: term()) ::
          {:ok, String.t()} | {:error, String.t()}
  def nmap_command(target, ports) when is_binary(target) do
    with {:ok, {_, _, _, _} = address} <- :inet.parse_address(String.to_charlist(target)),
         {:ok, ports} <- ports(ports) do
      address = address |> :inet.ntoa() |> List.to_string()
      # Only canonical numeric IPv4 and integers enter this shell command.
      # Preserve host execution/cancellation through Tools.Bash rather than
      # starting a second unmanaged subprocess runner.
      {:ok, "nmap -sT -n --host-timeout 20s -p #{Enum.join(ports, ",")} -oX - #{address}"}
    else
      _ -> {:error, "Use one IPv4 address and 1 to 128 integer ports (1..65535)."}
    end
  end

  def nmap_command(_target, _ports), do: {:error, "Use one IPv4 address and explicit ports."}

  @doc "Flags selected exposed services for review; this is policy, not vulnerability detection."
  @spec assess_ports(ports :: term()) :: {:ok, [map()]} | {:error, String.t()}
  def assess_ports(input)
  def assess_ports([]), do: {:ok, []}

  def assess_ports(input) do
    with {:ok, ports} <- ports(input) do
      {:ok,
       for(
         port <- ports,
         port in [23, 2375],
         do: %{"port" => port, "finding" => "Review access restrictions and transport protection"}
       )}
    end
  end

  defp ports(ports) when is_list(ports) and length(ports) in 1..128 do
    if Enum.all?(ports, &(is_integer(&1) and &1 in 1..65535)),
      do: {:ok, ports |> Enum.uniq() |> Enum.sort()},
      else: {:error, "Ports must be integers in 1..65535."}
  end

  defp ports(_ports), do: {:error, "Supply 1 to 128 explicit ports."}
end
