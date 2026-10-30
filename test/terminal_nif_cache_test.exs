Code.require_file("../scripts/support/terminal_nif_cache.exs", __DIR__)

defmodule TerminalNifCacheTest do
  use ExUnit.Case, async: true

  alias Lemieux.Scripts.TerminalNifCache

  test "selects the latest compatible NIF without changing native version or ABI" do
    checksum = String.duplicate("a", 64)

    contents =
      for nif <- ~w(2.16 2.17 2.18),
          target <- ~w(x86_64-unknown-linux-gnu aarch64-apple-darwin) do
        prefix = if nif == "2.16", do: "", else: "lib"
        ~s("#{prefix}ex_ratatui-v0.18.0-nif-#{nif}-#{target}.so.tar.gz" => "sha256:#{checksum}")
      end
      |> Enum.join("\n")

    assert TerminalNifCache.select(contents, "2.17", "Linux", "x86_64") ==
             {"libex_ratatui-v0.18.0-nif-2.17-x86_64-unknown-linux-gnu.so.tar.gz", "0.18.0",
              checksum}

    assert {name, "0.18.0", ^checksum} =
             TerminalNifCache.select(contents, "2.18", "Darwin", "arm64")

    assert name =~ "2.18-aarch64-apple-darwin"

    assert_raise ArgumentError, fn ->
      TerminalNifCache.select(contents, "2.18", "Linux", "x86_64", "musl")
    end

    assert_raise ArgumentError, fn ->
      TerminalNifCache.select(contents, "2.15", "Linux", "x86_64")
    end

    ambiguous = contents <> String.replace(contents, "v0.18.0", "v0.19.0")

    assert_raise ArgumentError, fn ->
      TerminalNifCache.select(ambiguous, "2.18", "Linux", "x86_64")
    end
  end

  @tag :tmp_dir
  test "a tampered or interrupted download never enters the cache", %{tmp_dir: root} do
    selection = {"libexample.so.tar.gz", "0.18.0", digest("expected")}

    assert_raise ArgumentError, ~r/wrong checksum/, fn ->
      TerminalNifCache.cache(root, selection, fn _url, path -> File.write!(path, "tampered") end)
    end

    assert File.ls!(root) == []

    assert_raise RuntimeError, "download failed", fn ->
      TerminalNifCache.cache(root, selection, fn _url, path ->
        File.write!(path, "partial")
        raise "download failed"
      end)
    end

    assert File.ls!(root) == []
  end

  @tag :tmp_dir
  test "verified cache is reused and existing tampering is refused", %{tmp_dir: root} do
    selection = {"libexample.so.tar.gz", "0.18.0", digest("expected")}
    parent = self()

    fetch = fn url, path ->
      send(parent, {:fetch, url})
      File.write!(path, "expected")
    end

    path = TerminalNifCache.cache(root, selection, fetch)

    assert_receive {:fetch,
                    "https://github.com/mcass19/ex_ratatui/releases/download/v0.18.0/libexample.so.tar.gz"}

    assert TerminalNifCache.cache(root, selection, fetch) == path
    # Fetch runs synchronously before cache/3 returns, so an unexpected call is
    # already in this mailbox. Waiting cannot discover any additional call.
    refute_received {:fetch, _}
    File.write!(path, "tampered")

    assert_raise ArgumentError, ~r/existing CI cache/, fn ->
      TerminalNifCache.cache(root, selection, fetch)
    end

    refute_received {:fetch, _}
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
