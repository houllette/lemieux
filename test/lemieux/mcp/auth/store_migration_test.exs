defmodule Lemieux.MCP.Auth.StoreMigrationTest do
  # `lmx` kept MCP OAuth tokens in `~/.lemieux/credentials.json`, the one file
  # of its own outside `~/.lmx`. They now live in `~/.lmx/mcp-credentials.json`
  # and an existing file is moved there once.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.OAuth
  alias Lemieux.CLI.Options
  alias Lemieux.CLI.Runtime
  alias Lemieux.MCP.Auth.Store

  import Bitwise

  @moduletag :tmp_dir

  @issuer "https://auth.example.com"
  @resource "https://mcp.example.com"

  defp posix?, do: match?({:unix, _}, :os.type())

  defp legacy(tmp_dir, records) do
    path = Path.join([tmp_dir, "old", "credentials.json"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, JSON.encode!(records))
    File.chmod!(path, 0o600)
    path
  end

  test "moves the records, owner-only, and leaves no second copy behind", %{tmp_dir: tmp_dir} do
    record = %{"access_token" => "at", "refresh_token" => "rt"}
    from = legacy(tmp_dir, %{Store.token_key(@issuer, @resource) => record})
    to = Path.join([tmp_dir, "lmx", "mcp-credentials.json"])

    assert Store.File.migrate(from, to) == :ok

    assert {:ok, %{"refresh_token" => "rt"}} =
             Store.fetch_token(Store.File.new(to), @issuer, @resource)

    if posix?() do
      assert (File.stat!(to).mode &&& 0o777) == 0o600
      assert (File.stat!(Path.dirname(to)).mode &&& 0o777) == 0o700
    end

    refute File.exists?(from)
  end

  test "happens once: a file already at the new path is the one in use", %{tmp_dir: tmp_dir} do
    from = legacy(tmp_dir, %{Store.token_key(@issuer, @resource) => %{"access_token" => "old"}})
    to = Path.join(tmp_dir, "mcp-credentials.json")
    :ok = Store.put_token(Store.File.new(to), @issuer, @resource, %{"access_token" => "new"})

    assert Store.File.migrate(from, to) == :ok

    assert {:ok, %{"access_token" => "new"}} =
             Store.fetch_token(Store.File.new(to), @issuer, @resource)

    assert File.exists?(from)
  end

  # `lmx --sandbox` creates a token file it is about to hide before the
  # first token exists (`Store.File.create/1`); that must not cost the move.
  test "an empty file at the new path holds nothing to lose and is moved over",
       %{tmp_dir: tmp_dir} do
    from = legacy(tmp_dir, %{Store.token_key(@issuer, @resource) => %{"access_token" => "old"}})
    to = Path.join(tmp_dir, "mcp-credentials.json")
    :ok = Store.File.create(to)

    assert Store.File.migrate(from, to) == :ok

    assert {:ok, %{"access_token" => "old"}} =
             Store.fetch_token(Store.File.new(to), @issuer, @resource)

    refute File.exists?(from)
  end

  test "a new path that will not parse is left for a person", %{tmp_dir: tmp_dir} do
    from = legacy(tmp_dir, %{Store.token_key(@issuer, @resource) => %{"access_token" => "old"}})
    to = Path.join(tmp_dir, "mcp-credentials.json")
    File.write!(to, "not json")

    assert Store.File.migrate(from, to) == :ok

    assert File.read!(to) == "not json"
    assert File.exists?(from)
  end

  describe "create/1" do
    test "makes an empty store, owner-only, that reads as no records", %{tmp_dir: tmp_dir} do
      path = Path.join([tmp_dir, "fresh", "mcp-credentials.json"])

      assert Store.File.create(path) == :ok

      assert File.read!(path) == "{}"
      assert Store.fetch_token(Store.File.new(path), @issuer, @resource) == :error

      if posix?() do
        assert (File.stat!(path).mode &&& 0o777) == 0o600
        assert (File.stat!(Path.dirname(path)).mode &&& 0o777) == 0o700
      end
    end

    test "never replaces a file that is there", %{tmp_dir: tmp_dir} do
      path = Path.join(tmp_dir, "mcp-credentials.json")
      :ok = Store.put_token(Store.File.new(path), @issuer, @resource, %{"access_token" => "kept"})

      assert Store.File.create(path) == :ok

      assert {:ok, %{"access_token" => "kept"}} =
               Store.fetch_token(Store.File.new(path), @issuer, @resource)
    end
  end

  test "nothing to move is nothing to do", %{tmp_dir: tmp_dir} do
    to = Path.join(tmp_dir, "mcp-credentials.json")

    assert Store.File.migrate(Path.join(tmp_dir, "absent.json"), to) == :ok
    refute File.exists?(to)
  end

  test "a file that will not parse is reported and left where it is", %{tmp_dir: tmp_dir} do
    from = Path.join(tmp_dir, "credentials.json")
    File.write!(from, "not json")
    to = Path.join(tmp_dir, "mcp-credentials.json")

    assert {:error, reason} = Store.File.migrate(from, to)
    assert reason =~ from
    assert File.read!(from) == "not json"
    refute File.exists?(to)
  end

  test "a store given the old file moves it when first used, not when built", %{
    tmp_dir: tmp_dir
  } do
    from = legacy(tmp_dir, %{Store.token_key(@issuer, @resource) => %{"access_token" => "at"}})
    to = Path.join(tmp_dir, "mcp-credentials.json")

    store = Store.File.new(to, migrate_from: from)
    assert File.exists?(from)
    refute File.exists?(to)

    assert {:ok, %{"access_token" => "at"}} = Store.fetch_token(store, @issuer, @resource)
    refute File.exists?(from)

    :ok = Store.put_token(store, @issuer, "https://other.example.com", %{"access_token" => "b"})
    assert {:ok, %{"access_token" => "at"}} = Store.fetch_token(store, @issuer, @resource)
  end

  @tag skip: if(match?({:win32, _}, :os.type()), do: "POSIX modes", else: false)
  test "a directory the store creates for itself is owner-only", %{tmp_dir: tmp_dir} do
    path = Path.join([tmp_dir, "fresh", "credentials.json"])

    :ok = Store.put_token(Store.File.new(path), @issuer, @resource, %{"access_token" => "at"})

    assert (File.stat!(Path.dirname(path)).mode &&& 0o777) == 0o700
  end

  describe "lmx's default" do
    test "is beside its other files, and the library's default is where it used to be" do
      assert OAuth.default_store() ==
               Path.join([System.user_home!(), ".lmx", "mcp-credentials.json"])

      assert OAuth.legacy_store() == Store.File.default_path()
      assert Store.File.default_path() =~ ".lemieux"
    end

    test "is what the options fall back to without --credentials or LMX_CREDENTIALS" do
      if System.get_env("LMX_CREDENTIALS") do
        assert Options.default_credentials() == System.get_env("LMX_CREDENTIALS")
      else
        assert Options.default_credentials() == OAuth.default_store()
      end
    end

    # Decided without touching either file: these are the real home's paths.
    test "moves the old file only into lmx's own default, never into a named file" do
      default = OAuth.default_store()

      assert Runtime.credential_store(default) ==
               {Store.File, %{path: default, migrate_from: OAuth.legacy_store()}}

      assert Runtime.credential_store("/somewhere/named.json") ==
               {Store.File, "/somewhere/named.json"}
    end
  end
end
