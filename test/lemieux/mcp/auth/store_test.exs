defmodule Lemieux.MCP.Auth.StoreTest do
  @moduledoc """
  Where credentials live, and what may share one.

  Two of these tests are about keying, which sounds like bookkeeping and is
  not: a token is minted for one resource and a registration belongs to one
  authorization server, and getting either key too coarse hands a credential to
  something it was never issued for.
  """

  use ExUnit.Case, async: true

  alias Lemieux.MCP.Auth.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    %{store: Store.File.new(Path.join(tmp_dir, "credentials.json"))}
  end

  describe "tokens" do
    test "survive being written and read back", %{store: store} do
      token = %{"access_token" => "at-1", "refresh_token" => "rt-1", "expires_at" => 1_800_000}

      :ok = Store.put_token(store, "https://auth.example.com", "https://mcp.example.com", token)

      assert {:ok, read} =
               Store.fetch_token(store, "https://auth.example.com", "https://mcp.example.com")

      assert read["access_token"] == "at-1"
      assert read["refresh_token"] == "rt-1"
      assert read["expires_at"] == 1_800_000
    end

    test "are keyed by issuer and resource, so two servers behind one authorization server " <>
           "do not share one",
         %{store: store} do
      issuer = "https://github.com/login/oauth"

      :ok = Store.put_token(store, issuer, "https://a.example.com/mcp", %{"access_token" => "a"})
      :ok = Store.put_token(store, issuer, "https://b.example.com/mcp", %{"access_token" => "b"})

      assert {:ok, %{"access_token" => "a"}} =
               Store.fetch_token(store, issuer, "https://a.example.com/mcp")

      assert {:ok, %{"access_token" => "b"}} =
               Store.fetch_token(store, issuer, "https://b.example.com/mcp")
    end

    test "carry the issuer they were minted by, not only the key they are filed under",
         %{store: store} do
      :ok = Store.put_token(store, "https://auth.example.com", "https://mcp.example.com", %{})

      assert {:ok, token} =
               Store.fetch_token(store, "https://auth.example.com", "https://mcp.example.com")

      assert token["issuer"] == "https://auth.example.com"
      assert token["resource"] == "https://mcp.example.com"
    end

    test "can be deleted, which is what a failed refresh does", %{store: store} do
      :ok = Store.put_token(store, "https://auth.example.com", "https://mcp.example.com", %{})
      :ok = Store.delete_token(store, "https://auth.example.com", "https://mcp.example.com")

      assert Store.fetch_token(store, "https://auth.example.com", "https://mcp.example.com") ==
               :error
    end

    test "are absent rather than an error before anything is written", %{store: store} do
      assert Store.fetch_token(store, "https://auth.example.com", "https://mcp.example.com") ==
               :error
    end
  end

  describe "client registrations" do
    test "are keyed by issuer alone, because a client id belongs to one authorization server",
         %{store: store} do
      :ok = Store.put_client(store, "https://one.example.com", %{"client_id" => "c1"})
      :ok = Store.put_client(store, "https://two.example.com", %{"client_id" => "c2"})

      assert {:ok, %{"client_id" => "c1"}} = Store.fetch_client(store, "https://one.example.com")
      assert {:ok, %{"client_id" => "c2"}} = Store.fetch_client(store, "https://two.example.com")
    end

    test "do not collide with a token filed under the same issuer", %{store: store} do
      issuer = "https://auth.example.com"

      :ok = Store.put_client(store, issuer, %{"client_id" => "c1"})
      :ok = Store.put_token(store, issuer, issuer, %{"access_token" => "at"})

      assert {:ok, %{"client_id" => "c1"}} = Store.fetch_client(store, issuer)
      assert {:ok, %{"access_token" => "at"}} = Store.fetch_token(store, issuer, issuer)
    end
  end

  describe "the file the default keeps them in" do
    test "is not readable by anyone else", %{store: {_module, path} = store} do
      :ok = Store.put_token(store, "https://auth.example.com", "https://mcp.example.com", %{})

      assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
      assert Bitwise.band(mode, 0o077) == 0
      assert Bitwise.band(mode, 0o777) == 0o600
    end

    test "is created along with any directory it needs", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "nested", "deeper", "credentials.json"])
      store = Store.File.new(path)

      :ok = Store.put_token(store, "https://auth.example.com", "https://mcp.example.com", %{})

      assert File.exists?(path)
    end

    test "survives being replaced by another store over the same path", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "credentials.json")

      :ok =
        Store.put_token(
          Store.File.new(path),
          "https://auth.example.com",
          "https://mcp.example.com",
          %{"access_token" => "at"}
        )

      assert {:ok, %{"access_token" => "at"}} =
               Store.fetch_token(
                 Store.File.new(path),
                 "https://auth.example.com",
                 "https://mcp.example.com"
               )
    end

    test "keeps what was already in it when something else is written", %{store: store} do
      :ok = Store.put_token(store, "https://a.example.com", "https://a.example.com", %{"n" => 1})
      :ok = Store.put_token(store, "https://b.example.com", "https://b.example.com", %{"n" => 2})

      assert {:ok, %{"n" => 1}} =
               Store.fetch_token(store, "https://a.example.com", "https://a.example.com")
    end

    test "reports a file it cannot parse rather than silently starting over", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "credentials.json")
      File.write!(path, "this is not json")

      assert {:error, reason} =
               Store.put_token(Store.File.new(path), "https://a.example.com", "https://a", %{})

      assert reason =~ "credentials.json"
    end
  end
end
