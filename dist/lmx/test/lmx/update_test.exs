defmodule Lmx.UpdateTest do
  use ExUnit.Case, async: true
  alias Lmx.Update
  alias Lmx.Update.Archive
  alias Lmx.Update.Signature

  @digest String.duplicate("a", 64)
  # Far above any real version, so a check against the running release always
  # sees this manifest as newer.
  @info %{
    "version" => "10.2.0",
    "target" => "macos_silicon",
    "sha256" => @digest,
    "build_id" => @digest,
    "native_id" => @digest,
    "dependency_id" => @digest,
    "config_id" => @digest,
    "erts" => "17.0.2",
    "elixir" => "1.20.2",
    "dependencies" => %{},
    "hot_modules" => [],
    "upgrade_from" => []
  }
  @latest "https://github.com/houllette/lemieux/releases/latest/download/update.json"
  @signature "https://github.com/houllette/lemieux/releases/download/v10.2.0/update.json.sig"

  # Throwaway keys, made fresh for this run; the release key never appears here.
  setup_all do
    {public, private} = :crypto.generate_key(:eddsa, :ed25519)
    {_other_public, other} = :crypto.generate_key(:eddsa, :ed25519)
    %{key: Base.encode64(public), private: private, other: other}
  end

  defp manifest(info),
    do:
      JSON.encode!(%{
        "schema_version" => 1,
        "version" => info["version"],
        "targets" => %{info["target"] => info}
      })

  # What check/1 returns for `info`: the entry plus the manifest it was signed in.
  defp offer(info, private) do
    body = manifest(info)

    Map.put(info, "signed_manifest", %{
      "manifest" => body,
      "signature" => Signature.sign(body, private)
    })
  end

  # Serves `routes` (URL => body) through Req's `into` callback, like GitHub
  # does, recording each request; anything else is a 404.
  defp serve(routes, owner \\ self()) do
    fn url, opts ->
      send(owner, {:requested, url})

      case Map.fetch(routes, url) do
        {:ok, body} ->
          {:cont, {_, response}} =
            opts[:into].({:data, body}, {%Req.Request{}, %Req.Response{status: 200}})

          {:ok, response}

        :error ->
          {:ok, %Req.Response{status: 404}}
      end
    end
  end

  defp requested do
    receive do
      {:requested, url} -> [url | requested()]
    after
      0 -> []
    end
  end

  @tag :tmp_dir
  test "rejects a corrupt archive before extraction", %{tmp_dir: tmp} = keys do
    info = %{@info | "target" => Lmx.Release.target()}

    get = fn _url, opts ->
      {:cont, {_, response}} =
        opts[:into].({:data, "corrupt"}, {%Req.Request{}, %Req.Response{status: 200}})

      {:ok, response}
    end

    assert {:error, :release_integrity} =
             Update.stage(offer(info, keys.private), home: tmp, get: get, public_key: keys.key)

    assert Path.wildcard(Path.join(tmp, "versions/*")) == []
    refute File.exists?(Path.join(tmp, ".update-lock"))
  end

  @tag :tmp_dir
  test "verified staging cannot reuse a modified payload", %{tmp_dir: tmp} = keys do
    info = %{@info | "target" => Lmx.Release.target()}
    archive = Path.join(tmp, "fixture.tar.gz")

    :ok =
      :erl_tar.create(
        to_charlist(archive),
        [
          {~c"releases/10.2.0/release.json", JSON.encode!(Map.drop(info, ["sha256"]))},
          {~c"bin/lmx", "fixture code: never execute"}
        ],
        [:compressed]
      )

    bytes = File.read!(archive)
    info = %{info | "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}

    get = fn _url, opts ->
      {:cont, {_, response}} =
        opts[:into].({:data, bytes}, {%Req.Request{}, %Req.Response{status: 200}})

      {:ok, response}
    end

    opts = [home: tmp, get: get, public_key: keys.key]
    offer = offer(info, keys.private)
    assert {:ok, staged} = Update.stage(offer, opts)
    assert staged.info == info
    refute File.exists?(Path.join(staged.directory, "download.tar.gz"))
    assert {:ok, ^staged} = Update.stage(offer, opts)
    File.write!(Path.join(staged.directory, ".unexpected"), "extra")
    assert {:error, :version_directory_conflict} = Update.stage(offer, opts)
    File.rm!(Path.join(staged.directory, ".unexpected"))
    File.write!(Path.join(staged.directory, "bin/lmx"), "modified")
    assert {:error, :version_directory_conflict} = Update.stage(offer, opts)
  end

  # install.py extracts with Python's "data" filter, which drops group write,
  # while staging's :erl_tar keeps the archive's mode. A Hex package's 0664
  # file made the two version directories of one archive differ, and staging
  # answered the one install.py had made with :version_directory_conflict on
  # every hourly check (install.py refused the updater's the same way).
  @tag :tmp_dir
  @tag :unix
  test "a version directory install.py made from the same archive is reused",
       %{tmp_dir: tmp} = keys do
    info = %{@info | "target" => Lmx.Release.target()}
    source = Path.join(tmp, "source")
    grammar = "lib/jsv-0.21.2/priv/grammars/email-address.abnf"
    File.mkdir_p!(Path.join(source, Path.dirname(grammar)))
    File.write!(Path.join(source, grammar), "grammar")
    File.chmod!(Path.join(source, grammar), 0o664)
    File.mkdir_p!(Path.join(source, "releases/10.2.0"))

    File.write!(
      Path.join(source, "releases/10.2.0/release.json"),
      JSON.encode!(Map.drop(info, ["sha256"]))
    )

    archive = Path.join(tmp, "fixture.tar.gz")

    :ok =
      :erl_tar.create(
        to_charlist(archive),
        for(top <- ["lib", "releases"], do: {~c"#{top}", ~c"#{Path.join(source, top)}"}),
        [:compressed]
      )

    bytes = File.read!(archive)
    info = %{info | "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)}

    get = fn _url, opts ->
      {:cont, {_, response}} =
        opts[:into].({:data, bytes}, {%Req.Request{}, %Req.Response{status: 200}})

      {:ok, response}
    end

    # The directory install.py makes: the same files, with the filter's modes.
    home = Path.join(tmp, "home")
    installed = Path.join([home, "versions", "10.2.0-" <> String.slice(info["build_id"], 0, 12)])
    File.mkdir_p!(installed)
    :ok = :erl_tar.extract(to_charlist(archive), [:compressed, cwd: to_charlist(installed)])
    assert Bitwise.band(File.stat!(Path.join(installed, grammar)).mode, 0o777) == 0o664
    File.chmod!(Path.join(installed, grammar), 0o644)

    assert {:ok, staged} =
             Update.stage(offer(info, keys.private), home: home, get: get, public_key: keys.key)

    assert staged.directory == installed
    assert Bitwise.band(File.stat!(Path.join(installed, grammar)).mode, 0o777) == 0o644
  end

  test "binary discovery offers only a manifest that verifies, and tolerates offline checks",
       keys do
    info = %{@info | "target" => Lmx.Release.target()}
    body = manifest(info)
    signature = Signature.sign(body, keys.private)
    get = serve(%{@latest => body, @signature => signature})

    assert {:ok, offer} = Update.check(get: get, public_key: keys.key)
    assert Map.delete(offer, "signed_manifest") == info
    assert offer["signed_manifest"] == %{"manifest" => body, "signature" => signature}
    # The signature comes from the release the manifest names, not from
    # `latest`, which can move between the two requests.
    assert requested() == [@latest, @signature]
    assert {:error, :update_unavailable} = Update.check(get: fn _, _ -> {:error, :offline} end)
  end

  test "an unsigned, altered or foreign-signed manifest is reported and never offered", keys do
    info = %{@info | "target" => Lmx.Release.target()}
    body = manifest(info)
    altered = manifest(%{info | "sha256" => String.duplicate("b", 64)})

    for {routes, reason} <- [
          {%{@latest => body}, :signature_missing},
          {%{@latest => altered, @signature => Signature.sign(body, keys.private)},
           :signature_invalid},
          {%{@latest => body, @signature => Signature.sign(body, keys.other)},
           :signature_invalid},
          {%{@latest => body, @signature => "not a signature\n"}, :signature_invalid}
        ] do
      assert {:unverified, "10.2.0", ^reason} =
               Update.check(get: serve(routes), public_key: keys.key)

      assert requested() == [@latest, @signature]
    end

    # A build without a key cannot verify anything, so it does not ask.
    assert {:unverified, "10.2.0", :signing_key_unset} =
             Update.check(get: serve(%{@latest => body}), public_key: "UNSET")

    assert requested() == [@latest]
  end

  test "an older or equal manifest is current, signed or not, without a signature request",
       keys do
    for version <- ["0.0.1", Lemieux.version()] do
      info = %{@info | "target" => Lmx.Release.target(), "version" => version}
      body = manifest(info)
      routes = %{@latest => body}
      assert :current = Update.check(get: serve(routes), public_key: keys.key)
      assert requested() == [@latest]
    end
  end

  @tag :tmp_dir
  test "staging refuses an offer without a verified manifest before locking or downloading",
       %{tmp_dir: tmp} = keys do
    info = %{@info | "target" => Lmx.Release.target()}
    get = fn _, _ -> flunk("must not download") end
    opts = [home: tmp, get: get, public_key: keys.key]
    offer = offer(info, keys.private)

    assert {:error, :unsigned_update} = Update.stage(info, opts)

    assert {:error, :signing_key_unset} =
             Update.stage(offer, Keyword.put(opts, :public_key, "UNSET"))

    # The entry must be the one the signature covers, digest included. The
    # signature itself is sound, so this is not reported as tampering.
    assert {:error, :offer_mismatch} =
             Update.stage(%{offer | "sha256" => String.duplicate("b", 64)}, opts)

    other_target = %{info | "target" => "not-#{Lmx.Release.target()}"}

    assert {:error, :offer_mismatch} =
             Update.stage(
               Map.merge(info, Map.take(offer(other_target, keys.private), ["signed_manifest"])),
               opts
             )

    assert {:error, :signature_invalid} = Update.stage(offer(info, keys.other), opts)

    assert {:error, :signature_invalid} =
             Update.stage(put_in(offer, ["signed_manifest", "signature"], "AAAA\n"), opts)

    refute File.exists?(Path.join(tmp, ".update-lock"))
    assert File.ls!(tmp) == []
  end

  test "the installed host explains every unverified update and keeps default notices" do
    for reason <- [:signing_key_unset, :signature_missing, :signature_invalid] do
      notice = Update.unverified_notice("10.2.0", reason)
      assert notice =~ "v10.2.0"
      assert notice =~ "not"
    end

    assert Update.unverified_notice("10.2.0", :signing_key_unset) =~
             "https://github.com/houllette/lemieux/releases"

    assert Update.unverified_notice("10.2.0", :signature_invalid) =~ "tampered"
    # Installation off, or the manual-install host: nothing installs by itself
    # once the signature appears, so the notice must not promise it.
    unsigned = Update.unverified_notice("10.2.0", :signature_missing)
    refute unsigned =~ "installs"
    assert unsigned =~ "once its signed manifest is published"
    assert Update.error_notice(:signature_invalid) =~ "signature verification"
    assert Update.error_notice(:signing_key_unset) =~ "no release-signing key"
    assert Update.error_notice(:download_failed) == nil
    assert Update.error_notice(:offer_mismatch) == nil
  end

  test "the Mix task's signed fixture verifies through the updater" do
    fixtures = Path.expand("../../../../test/fixtures/install", __DIR__)
    key = fixtures |> Path.join("signing-key.pub") |> File.read!()
    body = File.read!(Path.join(fixtures, "update.json"))
    signature = File.read!(Path.join(fixtures, "update.json.sig"))
    {:ok, public} = Signature.parse_public_key(key)
    assert :ok = Signature.verify(body, signature, public)

    assert :ok =
             Signature.verify(
               File.read!(Path.join(fixtures, "SHA256SUMS")),
               File.read!(Path.join(fixtures, "SHA256SUMS.sig")),
               public
             )

    routes = %{
      @latest => body,
      "https://github.com/houllette/lemieux/releases/download/v99.0.0/update.json.sig" =>
        signature
    }

    assert {:ok, %{"version" => "99.0.0", "target" => target}} =
             Update.check(get: serve(routes), public_key: key)

    assert target == Lmx.Release.target()
  end

  # Whether the lock's owner is alive is asked with `kill -0`. Like the other
  # :unix tests here, it covers what only the Unix host does: Windows gets
  # the manual-install host, which never stages or activates (host/1).
  @tag :tmp_dir
  @tag :unix
  test "does not disturb a live updater's lock", %{tmp_dir: tmp} = keys do
    File.write!(Path.join(tmp, ".update-lock"), System.pid())

    assert {:error, :update_in_progress} =
             Update.stage(offer(%{@info | "target" => Lmx.Release.target()}, keys.private),
               home: tmp,
               get: fn _, _ -> flunk("must not download") end,
               public_key: keys.key
             )

    assert File.read!(Path.join(tmp, ".update-lock")) == System.pid()
  end

  @tag :tmp_dir
  @tag :unix
  test "another session's installed release is reported even while discovery is offline", %{
    tmp_dir: tmp
  } do
    root = Path.join([tmp, "releases", "10.2.0"])
    File.mkdir_p!(root)
    File.write!(Path.join(root, "release.json"), JSON.encode!(Map.drop(@info, ["sha256"])))
    home = Path.join(tmp, "install")
    File.mkdir!(home)
    File.ln_s!(tmp, Path.join(home, "current"))

    assert {:installed, "10.2.0"} =
             Update.check(home: home, get: fn _, _ -> {:error, :offline} end)
  end

  test "hot eligibility requires the exact predecessor and native/runtime identity" do
    current = %{@info | "version" => "10.1.0"}
    next = %{@info | "upgrade_from" => [%{"version" => "10.1.0", "build_id" => @digest}]}
    assert Update.hot?(current, next)
    refute Update.hot?(current, %{@info | "upgrade_from" => []})
    refute Update.hot?(current, Map.put(next, "erts", "18"))
    refute Update.hot?(current, Map.put(next, "native_id", String.duplicate("b", 64)))
    refute Update.hot?(current, Map.put(next, "dependency_id", String.duplicate("b", 64)))
    refute Update.hot?(current, Map.put(next, "config_id", String.duplicate("b", 64)))
    refute Update.hot?(Map.drop(current, ["dependency_id"]), Map.drop(next, ["dependency_id"]))
    refute Update.hot?(Map.put(current, "build_id", String.duplicate("b", 64)), next)
  end

  @tag :tmp_dir
  test "a stalled request has a deadline and releases its files and lock",
       %{tmp_dir: tmp} = keys do
    owner = self()

    get = fn _, _ ->
      send(owner, {:request, self()})

      receive do
        :never -> {:error, :offline}
      end
    end

    assert {:error, :update_unavailable} = Update.check(get: get, request_timeout: 10)
    assert_receive {:request, request}
    refute Process.alive?(request)

    assert {:error, :download_failed} =
             Update.stage(offer(%{@info | "target" => Lmx.Release.target()}, keys.private),
               home: tmp,
               get: get,
               request_timeout: 10,
               public_key: keys.key
             )

    assert_receive {:request, request}
    refute Process.alive?(request)
    refute File.exists?(Path.join(tmp, ".update-lock"))
    assert Path.wildcard(Path.join(tmp, "versions/*")) == []
  end

  test "does not accept prereleases, wrong targets or invalid hashes" do
    manifest = %{
      "schema_version" => 1,
      "version" => "10.2.0",
      "targets" => %{"macos_silicon" => @info}
    }

    assert {:ok, @info} = Update.select(manifest, "macos_silicon")
    assert {:error, :invalid_manifest} = Update.select(manifest, "linux")

    assert {:error, :invalid_manifest} =
             Update.select(%{manifest | "version" => "10.2.0-rc1"}, "macos_silicon")

    assert {:error, :invalid_manifest} =
             Update.select(
               put_in(manifest, ["targets", "macos_silicon", "sha256"], "bad"),
               "macos_silicon"
             )
  end

  @tag :tmp_dir
  test "rejects path traversal before unpacking", %{tmp_dir: tmp} do
    path = Path.join(tmp, "escape.tar.gz")
    :ok = :erl_tar.create(to_charlist(path), [{~c"../outside", "payload"}], [:compressed])
    assert {:error, :unsafe_archive} = Archive.validate(path)

    for name <- [~c"bin//lmx", ~c"bin/lmx/child"] do
      :ok =
        :erl_tar.create(to_charlist(path), [{~c"bin/lmx", "file"}, {name, "payload"}], [
          :compressed
        ])

      assert {:error, :unsafe_archive} = Archive.validate(path)
    end
  end

  @tag :tmp_dir
  @tag :unix
  test "rejects links before unpacking", %{tmp_dir: tmp} do
    path = Path.join(tmp, "escape.tar.gz")
    source = Path.join(tmp, "link")
    File.ln_s!("/etc/passwd", source)
    :ok = :erl_tar.create(to_charlist(path), [to_charlist(source)], [:compressed])
    assert {:error, :unsafe_archive} = Archive.validate(path)
  end

  # The modes the published Windows archive carries (0.8.0: every file 0666
  # or 0777, its one directory 0777), which the release gate must unpack to
  # inspect, and the updater's Unix rule must still refuse.
  @tag :tmp_dir
  @tag :unix
  test "admits modes writable by others only when told to, and setuid never", %{tmp_dir: tmp} do
    windows = Path.join(tmp, "windows.tar.gz")
    file = Path.join(tmp, "file")
    directory = Path.join(tmp, "dir")
    File.write!(file, "packaged file")
    File.chmod!(file, 0o666)
    File.mkdir!(directory)
    File.chmod!(directory, 0o777)

    :ok =
      :erl_tar.create(
        to_charlist(windows),
        [{~c"bin/lmx", to_charlist(file)}, {~c"lib/include", to_charlist(directory)}],
        [:compressed]
      )

    assert {:error, :unsafe_archive} = Archive.validate(windows)
    assert :ok = Archive.validate(windows, writable_by_others: true)

    setuid = Path.join(tmp, "setuid.tar.gz")
    File.chmod!(file, 0o4755)
    :ok = :erl_tar.create(to_charlist(setuid), [{~c"bin/lmx", to_charlist(file)}], [:compressed])
    assert {:error, :unsafe_archive} = Archive.validate(setuid)
    assert {:error, :unsafe_archive} = Archive.validate(setuid, writable_by_others: true)
  end

  @tag :tmp_dir
  @tag :unix
  test "restart activation leaves the running release intact and switches the pointer", %{
    tmp_dir: tmp
  } do
    root = Path.join(tmp, "old")
    version = Lemieux.version()
    File.mkdir_p!(Path.join([root, "releases", version]))

    File.write!(
      Path.join([root, "releases", version, "release.json"]),
      JSON.encode!(%{@info | "version" => version})
    )

    directory = Path.join([tmp, "versions", "new"])
    File.mkdir_p!(Path.join([directory, "releases", @info["version"]]))

    File.write!(
      Path.join([directory, "releases", @info["version"], "release.json"]),
      JSON.encode!(Map.drop(@info, ["sha256"]))
    )

    File.ln_s!(root, Path.join(tmp, "current"))
    {:ok, payload} = Lmx.Update.Payload.fingerprint(directory)

    assert {:ok, :restart} =
             Update.activate(%{directory: directory, info: @info, payload: payload}, self(),
               home: tmp,
               root: root,
               extensions?: false
             )

    assert {:ok, ^directory} = File.read_link(Path.join(tmp, "current"))
    File.mkdir!(Path.join(tmp, "failed-updates"))
    File.write!(Path.join([tmp, "failed-updates", @info["build_id"]]), "failed health check")

    assert {:error, :quarantined_update} =
             Update.activate(%{directory: directory, info: @info, payload: payload}, self(),
               home: tmp,
               root: root
             )

    File.rm!(Path.join([tmp, "failed-updates", @info["build_id"]]))
    assert File.regular?(Path.join([root, "releases", version, "release.json"]))
    # An old screen must never undo another screen's newer installation.
    File.write!(
      Path.join([directory, "releases", @info["version"], "release.json"]),
      JSON.encode!(Map.drop(Map.put(@info, "version", "10.3.0"), ["sha256"]))
    )

    older = Path.join([tmp, "versions", "older"])
    File.cp_r!(directory, older)

    File.write!(
      Path.join([older, "releases", @info["version"], "release.json"]),
      JSON.encode!(Map.drop(@info, ["sha256"]))
    )

    {:ok, payload} = Lmx.Update.Payload.fingerprint(older)

    assert {:error, :superseded_update} =
             Update.activate(%{directory: older, info: @info, payload: payload}, self(),
               home: tmp,
               root: root
             )

    assert {:ok, ^directory} = File.read_link(Path.join(tmp, "current"))
    File.write!(Path.join(older, ".tampered"), "new file after download")

    assert {:error, :release_integrity} =
             Update.activate(%{directory: older, info: @info, payload: payload}, self(),
               home: tmp,
               root: root
             )
  end
end
