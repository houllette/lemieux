defmodule Lemieux.WebFetch.AddressTest do
  use ExUnit.Case, async: true

  alias Lemieux.WebFetch.Address

  describe "classify/1" do
    test "public unicast addresses are public" do
      assert Address.classify({93, 184, 216, 34}) == :public
      assert Address.classify({1, 1, 1, 1}) == :public

      assert Address.classify({0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}) ==
               :public
    end

    test "loopback, private, link-local and unique-local ranges are named" do
      assert Address.classify({127, 0, 0, 1}) == :loopback
      assert Address.classify({127, 200, 1, 9}) == :loopback
      assert Address.classify({0, 0, 0, 0, 0, 0, 0, 1}) == :loopback
      assert Address.classify({10, 0, 0, 5}) == :private
      assert Address.classify({172, 16, 0, 1}) == :private
      assert Address.classify({172, 31, 255, 255}) == :private
      assert Address.classify({172, 32, 0, 1}) == :public
      assert Address.classify({192, 168, 1, 1}) == :private
      assert Address.classify({100, 64, 0, 1}) == :private
      assert Address.classify({169, 254, 169, 254}) == :link_local
      assert Address.classify({0xFE80, 0, 0, 0, 0, 0, 0, 1}) == :link_local
      assert Address.classify({0xFC00, 0, 0, 0, 0, 0, 0, 1}) == :unique_local
      assert Address.classify({0xFD12, 0x3456, 0, 0, 0, 0, 0, 1}) == :unique_local
    end

    test "multicast, unspecified and reserved ranges are refused families" do
      assert Address.classify({224, 0, 0, 1}) == :multicast
      assert Address.classify({0xFF02, 0, 0, 0, 0, 0, 0, 1}) == :multicast
      assert Address.classify({0, 0, 0, 0}) == :unspecified
      assert Address.classify({0, 0, 0, 0, 0, 0, 0, 0}) == :unspecified
      assert Address.classify({255, 255, 255, 255}) == :reserved
      assert Address.classify({192, 0, 2, 1}) == :reserved
      assert Address.classify({198, 51, 100, 7}) == :reserved
      assert Address.classify({203, 0, 113, 9}) == :reserved
      assert Address.classify({0x2001, 0xDB8, 0, 0, 0, 0, 0, 1}) == :reserved
    end

    test "IPv6 forms that wrap an IPv4 address are judged by the wrapped address" do
      assert Address.classify({0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 0x0001}) == :loopback
      assert Address.classify({0, 0, 0, 0, 0, 0xFFFF, 0x0A00, 0x0005}) == :private
      assert Address.classify({0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE}) == :link_local
      assert Address.classify({0, 0, 0, 0, 0, 0xFFFF, 0x5DB8, 0xD822}) == :public
      assert Address.classify({0x2002, 0x0A00, 0x0001, 0, 0, 0, 0, 1}) == :private
      assert Address.classify({0x64, 0xFF9B, 0, 0, 0, 0, 0xC0A8, 0x0101}) == :private
      assert Address.classify({0x64, 0xFF9B, 1, 0, 0, 0, 0, 1}) == :private
    end
  end

  describe "check/2" do
    test "passes only when every address is public" do
      assert :ok = Address.check([{93, 184, 216, 34}, {1, 1, 1, 1}])

      assert {:error, {{10, 0, 0, 5}, :private}} =
               Address.check([{93, 184, 216, 34}, {10, 0, 0, 5}])
    end

    test "refuses loopback by default and admits only loopback under the test allowance" do
      assert {:error, {{127, 0, 0, 1}, :loopback}} = Address.check([{127, 0, 0, 1}])
      assert :ok = Address.check([{127, 0, 0, 1}], allow_loopback: true)

      assert {:error, {{10, 0, 0, 1}, :private}} =
               Address.check([{10, 0, 0, 1}], allow_loopback: true)
    end
  end

  describe "resolve/1" do
    test "a literal address resolves to itself without a lookup" do
      assert Address.resolve("127.0.0.1") == {:ok, [{127, 0, 0, 1}]}
      assert Address.resolve("::1") == {:ok, [{0, 0, 0, 0, 0, 0, 0, 1}]}
    end

    test "a name nothing resolves is unresolvable" do
      assert Address.resolve("no-such-host.invalid") == {:error, :unresolvable}
    end
  end

  test "to_host/1 spells IPv6 literals with brackets" do
    assert Address.to_host({127, 0, 0, 1}) == "127.0.0.1"
    assert Address.to_host({0, 0, 0, 0, 0, 0, 0, 1}) == "[::1]"
  end
end
