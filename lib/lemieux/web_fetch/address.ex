defmodule Lemieux.WebFetch.Address do
  @moduledoc """
  The address policy behind `Lemieux.Tools.WebFetch`: which IP addresses a
  fetch may connect to.

  A URL names a host, and a host is whatever DNS says it is. A fetch tool
  that connects to "whatever DNS says" is a tool that will, sooner or later,
  be handed `http://169.254.169.254/latest/meta-data/` or a hostname somebody
  registered to point at `10.0.0.5`, and will read a cloud credential or an
  internal dashboard into the model's context. That is the server-side request
  forgery the roadmap conditional named, and it is why the policy is on the
  *resolved address*, not the hostname: names are the attacker's, addresses
  are the network's.

  `classify/1` sorts an address into the family it belongs to; `check/2`
  turns that into a decision. Everything non-public is refused — loopback,
  the RFC 1918 and CGNAT private ranges, link-local (where cloud metadata
  services live), IPv6 unique-local, multicast, unspecified and the reserved
  and documentation blocks — and IPv6 addresses that merely wrap an IPv4
  address (`::ffff:127.0.0.1`, 6to4, NAT64) are judged by the address they
  wrap, because otherwise the wrapping is the bypass.

  The one exception is deliberately ugly. `allow_loopback: true` lets a test
  suite point the tool at a listener on `127.0.0.1`, and nothing else: it
  does not open private ranges, and it is spelled `unsafe_allow_loopback_for_tests`
  on the tool so that it cannot be mistaken for a production knob.
  """

  import Bitwise

  @typedoc "An IPv4 or IPv6 address as `:inet` represents it."
  @type ip :: :inet.ip_address()

  @typedoc "The family an address belongs to; only `:public` may be fetched."
  @type class ::
          :public
          | :loopback
          | :private
          | :link_local
          | :unique_local
          | :multicast
          | :unspecified
          | :reserved

  @doc """
  Resolves `host` to every address it names.

  A literal address resolves to itself. A name is looked up for both
  families, because a host with an AAAA record pointing somewhere private is
  as much a problem as one with an A record doing the same, and a check that
  only asked for one family would miss the other.
  """
  @spec resolve(host :: String.t()) :: {:ok, [ip()]} | {:error, :unresolvable}
  def resolve(host) when is_binary(host) do
    charlist = String.to_charlist(host)

    case :inet.parse_strict_address(charlist) do
      {:ok, address} -> {:ok, [address]}
      {:error, :einval} -> lookup(charlist)
    end
  end

  defp lookup(charlist) do
    addresses =
      for family <- [:inet, :inet6],
          {:ok, found} <- [:inet.getaddrs(charlist, family)],
          address <- found,
          uniq: true,
          do: address

    if addresses == [], do: {:error, :unresolvable}, else: {:ok, addresses}
  end

  @doc """
  Decides whether every address in `addresses` may be connected to.

  All of them must pass, not just the one that will be used: a name that
  resolves to one public and one private address is a name whose owner is
  trying something, and connecting to the public one today does not make
  the private one go away tomorrow.
  """
  @spec check(addresses :: [ip()], opts :: [allow_loopback: boolean()]) ::
          :ok | {:error, {ip(), class()}}
  def check(addresses, opts \\ []) when is_list(addresses) and is_list(opts) do
    allow_loopback? = Keyword.get(opts, :allow_loopback, false)

    Enum.find_value(addresses, :ok, fn address ->
      case classify(address) do
        :public -> nil
        :loopback when allow_loopback? -> nil
        class -> {:error, {address, class}}
      end
    end)
  end

  @doc "Sorts an address into the family that decides whether it may be fetched."
  @spec classify(address :: ip()) :: class()
  def classify({0, _b, _c, _d}), do: :unspecified
  def classify({127, _b, _c, _d}), do: :loopback
  def classify({10, _b, _c, _d}), do: :private
  def classify({172, b, _c, _d}) when b in 16..31, do: :private
  def classify({192, 168, _c, _d}), do: :private
  # 100.64/10 is carrier-grade NAT: private in everything but name.
  def classify({100, b, _c, _d}) when b in 64..127, do: :private
  def classify({169, 254, _c, _d}), do: :link_local
  def classify({a, _b, _c, _d}) when a in 224..239, do: :multicast
  def classify({a, _b, _c, _d}) when a >= 240, do: :reserved
  # IETF protocol assignments, the three documentation nets and the
  # benchmarking block are not routable; refusing them costs nothing.
  def classify({192, 0, 0, _d}), do: :reserved
  def classify({192, 0, 2, _d}), do: :reserved
  def classify({198, 51, 100, _d}), do: :reserved
  def classify({203, 0, 113, _d}), do: :reserved
  def classify({198, b, _c, _d}) when b in 18..19, do: :reserved
  def classify({_a, _b, _c, _d}), do: :public

  def classify({0, 0, 0, 0, 0, 0, 0, 0}), do: :unspecified
  def classify({0, 0, 0, 0, 0, 0, 0, 1}), do: :loopback
  # IPv4-mapped (::ffff:a.b.c.d), the deprecated IPv4-compatible form and
  # the SIIT prefix all carry an IPv4 address in the low 32 bits; judge that.
  def classify({0, 0, 0, 0, 0, 0xFFFF, a, b}), do: classify(embedded(a, b))
  def classify({0, 0, 0, 0, 0xFFFF, 0, a, b}), do: classify(embedded(a, b))
  def classify({0, 0, 0, 0, 0, 0, a, b}), do: classify(embedded(a, b))
  # NAT64: the well-known prefix wraps a public address (judge it); the
  # local-use prefix is private by definition.
  def classify({0x64, 0xFF9B, 0, 0, 0, 0, a, b}), do: classify(embedded(a, b))
  def classify({0x64, 0xFF9B, 1, _d, _e, _f, _g, _h}), do: :private
  # 6to4 wraps the IPv4 address in the second and third groups.
  def classify({0x2002, a, b, _d, _e, _f, _g, _h}), do: classify(embedded(a, b))
  # Teredo obfuscates its IPv4 address; there is no honest way to judge it.
  def classify({0x2001, 0, _c, _d, _e, _f, _g, _h}), do: :reserved
  def classify({0x2001, 0xDB8, _c, _d, _e, _f, _g, _h}), do: :reserved

  def classify({a, _b, _c, _d, _e, _f, _g, _h}) do
    cond do
      (a &&& 0xFFC0) == 0xFE80 -> :link_local
      (a &&& 0xFE00) == 0xFC00 -> :unique_local
      (a &&& 0xFF00) == 0xFF00 -> :multicast
      true -> :public
    end
  end

  @doc "Formats an address the way a URL host must spell it."
  @spec to_host(address :: ip()) :: String.t()
  def to_host({_a, _b, _c, _d} = address), do: address |> :inet.ntoa() |> List.to_string()

  def to_host(address) when tuple_size(address) == 8,
    do: "[" <> (address |> :inet.ntoa() |> List.to_string()) <> "]"

  defp embedded(a, b), do: {a >>> 8, a &&& 0xFF, b >>> 8, b &&& 0xFF}
end
