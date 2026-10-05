defmodule Lmx.Update do
  @moduledoc """
  Installed-host updates from the project's GitHub releases.

  Nothing in a release manifest is trusted until it verifies. `check/1` reads
  `update.json` from the latest stable release and, when it names a newer
  version, fetches that version's `update.json.sig` and checks it against the
  Ed25519 key compiled into this build (`Lmx.Update.Signature`). Only a
  verified manifest is offered for installation; it travels with the offer,
  and `stage/2` verifies it again before using any digest in it, so no caller
  can hand the stager an unverified one. An unsigned or tampered manifest, or
  a build compiled without a key (`UNSET`), yields `{:unverified, version,
  reason}`: the TUI says why and installs nothing. Signing replaced
  checksum-only trust: the manifest and the archives come from the same
  origin, so a checksum alone let anyone able to upload a release asset run
  code on every installed `lmx` within the hour.

  Downloads are bounded, checked against the verified manifest and extracted
  into fresh version directories. Restart activation only replaces `current`.
  Hot installation copies only new versioned apps/config, never an overlay of
  a full archive onto a running release. SASL commits only after the same TUI
  responds and renders new code. A failed health check attempts a downgrade;
  the prior permanent release remains the next boot until health succeeds.
  Only a strictly newer version is ever offered or selected, so a replayed
  older manifest, signed or not, cannot downgrade an installation.

  A filesystem lock serializes installers/updaters across CLI processes. Each
  launch holds a process lease; multiple running processes and user extensions
  force restart installation. No update runs in an embedded library host.
  """

  alias Lmx.Release
  alias Lmx.Update.Archive
  alias Lmx.Update.Callbacks
  alias Lmx.Update.Payload
  alias Lmx.Update.Signature

  @origin "https://github.com/houllette/lemieux/releases"
  @security "https://github.com/houllette/lemieux/security"
  @max_download 150_000_000
  @max_manifest 100_000
  @max_signature 1_024
  # The verified manifest rides along with the offer it produced; see stage/2.
  @proof "signed_manifest"

  @typedoc "Why a newer release was not offered for installation."
  @type unverified :: :signing_key_unset | :signature_missing | :signature_invalid

  @doc "Callbacks supplied to the generic TUI by the installed host."
  @spec host(options :: map()) :: map() | nil
  def host(options) do
    home = System.get_env("LMX_INSTALL_HOME")
    root = System.get_env("LMX_RELEASE_ROOT")

    cond do
      home && root && Release.target() != "windows" ->
        opts = [
          home: home,
          root: root,
          extensions?: Map.get(options, :extensions, []) != []
        ]

        %{
          check: fn -> check(opts) end,
          stage: fn info -> stage(info, opts) end,
          apply: fn staged, tui -> activate(staged, tui, opts) end,
          refresh: fn -> __MODULE__.host(options) end,
          tasks: Lmx.Tasks,
          # Automatic installation stays on: check/1 only offers a release whose
          # manifest verified against the pinned key, and stage/2 checks again.
          auto?: System.get_env("LMX_AUTO_UPDATE") != "0" and not opts[:extensions?],
          unverified_notice: &unverified_notice/2,
          error_notice: &error_notice/1
        }

      root ->
        %{
          check: fn -> check() end,
          stage: fn _ -> {:error, :manual_install} end,
          apply: fn _, _ -> {:error, :manual_install} end,
          tasks: Lmx.Tasks,
          auto?: false,
          unverified_notice: &unverified_notice/2,
          error_notice: &error_notice/1
        }

      true ->
        nil
    end
  end

  @doc """
  Reads the stable binary manifest, independently of Hex publication.

  Returns `{:ok, info}` only for a newer release whose `update.json` verified
  against its `update.json.sig`. The signature is fetched from the release the
  manifest names (`/download/vVERSION/`), not from `latest`, so a release
  published between the two requests cannot pair one release's manifest with
  another's signature. A release that is not newer is `:current` without any
  signature request. `{:unverified, version, reason}` reports a newer release
  that cannot be installed; network failures stay `{:error, :update_unavailable}`.

  Options: `:get` (the HTTP function), `:request_timeout`, `:home` and
  `:public_key` (`release-signing.pub` text, overriding the compiled-in key;
  application env `:lmx, :release_public_key` does the same for tests).
  """
  @spec check(opts :: keyword()) ::
          {:ok, map()}
          | {:unverified, String.t(), unverified()}
          | {:installed, String.t()}
          | :current
          | {:error, term()}
  def check(opts \\ []) do
    get = Keyword.get(opts, :get, &Req.get/2)

    result =
      with {:ok, body} <-
             fetch(get, @origin <> "/latest/download/update.json", @max_manifest, opts),
           {:ok, manifest} <- JSON.decode(body),
           {:ok, info} <- select(manifest, Release.target()),
           :gt <- Version.compare(info["version"], selected_version(opts)) do
        authenticate(info, body, get, opts)
      else
        :lt -> :current
        :eq -> :current
        _ -> {:error, :update_unavailable}
      end

    report_selected(result, opts)
  rescue
    _ -> report_selected({:error, :update_unavailable}, opts)
  end

  # The version was read from an unverified manifest only to decide whether a
  # signature is worth fetching; nothing in it is offered until this passes.
  defp authenticate(info, body, get, opts) do
    version = info["version"]
    url = "#{@origin}/download/v#{version}/update.json.sig"

    with {:ok, key} <- signing_key(opts),
         {:ok, signature} <- fetch(get, url, @max_signature, opts),
         :ok <- Signature.verify(body, signature, key) do
      {:ok, Map.put(info, @proof, %{"manifest" => body, "signature" => signature})}
    else
      :unset -> {:unverified, version, :signing_key_unset}
      {:error, :not_found} -> {:unverified, version, :signature_missing}
      {:error, :signature_invalid} -> {:unverified, version, :signature_invalid}
      {:error, _unavailable} -> {:error, :update_unavailable}
    end
  end

  defp signing_key(opts) do
    text =
      Keyword.get_lazy(opts, :public_key, fn ->
        Application.get_env(:lmx, :release_public_key, Signature.pinned_text())
      end)

    case Signature.parse_public_key(text) do
      {:error, :invalid_public_key} -> raise ArgumentError, "invalid release public key"
      parsed -> parsed
    end
  end

  # Re-verifies the manifest an offer carries and returns the target entry it
  # signs. The TUI hands the offer back to stage/2; checking here as well means
  # no path (a future caller, a stale offer) can stage from unverified digests.
  # A manifest that verifies but does not describe the offer is
  # :offer_mismatch, not :signature_invalid: the signature is sound, and its
  # notice must not suggest that the release was tampered with.
  defp authenticated(%{@proof => %{"manifest" => body, "signature" => signature}} = info, opts)
       when is_binary(body) and is_binary(signature) do
    with {:ok, key} <- signing_key(opts),
         {:signature, :ok} <- {:signature, Signature.verify(body, signature, key)},
         {:ok, manifest} <- JSON.decode(body),
         {:ok, entry} <- select(manifest, Release.target()),
         true <- entry == Map.delete(info, @proof) do
      {:ok, entry}
    else
      :unset -> {:error, :signing_key_unset}
      {:signature, _invalid} -> {:error, :signature_invalid}
      _mismatch -> {:error, :offer_mismatch}
    end
  end

  defp authenticated(_info, opts) do
    case signing_key(opts) do
      :unset -> {:error, :signing_key_unset}
      {:ok, _key} -> {:error, :unsigned_update}
    end
  end

  @doc "What the TUI says about a newer release that was not verified, so not installed."
  @spec unverified_notice(version :: String.t(), reason :: unverified()) :: String.t()
  def unverified_notice(version, :signing_key_unset),
    do:
      "lmx v#{version} is available. This build has no release-signing key, so it cannot verify " <>
        "updates and will not install them: download v#{version} from #{@origin} and reinstall it."

  # Worded for every host: once the signature appears, the next hourly check
  # installs the update only where automatic installation is on; elsewhere
  # (LMX_AUTO_UPDATE=0, selected extensions, the manual-install host) it says
  # the update is available.
  def unverified_notice(version, :signature_missing),
    do:
      "lmx v#{version} is available, but its update manifest is not signed yet, so lmx " <>
        "cannot verify it and did not install it. lmx keeps running v#{Lemieux.version()} " <>
        "and will treat v#{version} as a normal update once its signed manifest is published."

  def unverified_notice(version, :signature_invalid),
    do:
      "lmx v#{version} was not installed: its update manifest failed signature verification, " <>
        "so the release may have been tampered with. lmx keeps running v#{Lemieux.version()}. " <>
        "Please report this at #{@security}."

  @doc "Notices for installation errors this host names; `nil` keeps the TUI's default."
  @spec error_notice(reason :: term()) :: String.t() | nil
  def error_notice(:signing_key_unset),
    do:
      "This build has no release-signing key, so it cannot verify updates and will not " <>
        "install them. Download the new version from #{@origin} and reinstall it."

  def error_notice(:unsigned_update),
    do:
      "The update carried no verified signature, so it was not installed · /update to check again."

  def error_notice(:signature_invalid),
    do:
      "The update was not installed: its manifest failed signature verification. " <>
        "lmx keeps running v#{Lemieux.version()}. Please report this at #{@security}."

  def error_notice(_reason), do: nil

  defp report_selected({:ok, _} = result, _opts), do: result

  defp report_selected(result, opts) do
    with home when is_binary(home) <- opts[:home],
         {:ok, %{"version" => version}} <- Release.current(Path.join(home, "current")),
         {:ok, parsed} <- Version.parse(version),
         :gt <- Version.compare(parsed, Lemieux.version()) do
      {:installed, version}
    else
      _ -> result
    end
  end

  defp selected_version(opts) do
    with home when is_binary(home) <- opts[:home],
         {:ok, selected} <- Release.current(Path.join(home, "current")),
         :gt <- Version.compare(selected["version"], Lemieux.version()) do
      selected["version"]
    else
      _ -> Lemieux.version()
    end
  end

  # A small release asset (the manifest or its signature). A 404 is reported
  # apart from other failures: for a signature it means the release is
  # unsigned, which the TUI must say, while an outage stays a quiet retry.
  defp fetch(get, url, limit, opts) do
    case request(
           get,
           url,
           Keyword.put(request_options(), :into, bounded(limit)),
           min(Keyword.get(opts, :request_timeout, 30_000), 30_000)
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= limit ->
        {:ok, body}

      {:ok, %{status: 404}} ->
        {:error, :not_found}

      _unavailable ->
        {:error, :unavailable}
    end
  end

  # Bodies are cut off while they stream, so an oversized or trickling
  # response never sits in memory. Error pages are discarded unread.
  defp bounded(limit) do
    started = System.monotonic_time(:millisecond)

    fn
      {:data, data}, {request, %{status: 200} = response} ->
        body = response.body <> data

        if byte_size(body) > limit or System.monotonic_time(:millisecond) - started > 30_000,
          do: raise("release metadata exceeds limit")

        {:cont, {request, %{response | body: body}}}

      {:data, _data}, {request, response} ->
        {:cont, {request, response}}
    end
  end

  @doc "Checks manifest versions, target and digests; URLs are always derived locally."
  @spec select(manifest :: map(), target :: String.t()) :: {:ok, map()} | {:error, term()}
  def select(%{"schema_version" => 1, "version" => version, "targets" => targets}, target)
      when is_binary(version) and is_map(targets) do
    with true <- byte_size(version) <= 128,
         {:ok, parsed} <- Version.parse(version),
         [] <- parsed.pre,
         nil <- parsed.build,
         info when is_map(info) <- Map.get(targets, target),
         true <- info["version"] == version and info["target"] == target,
         true <-
           Enum.all?(~w(sha256 build_id native_id dependency_id config_id), &digest?(info[&1])),
         true <- Enum.all?(~w(erts elixir), &(is_binary(info[&1]) and info[&1] != "")),
         true <- dependencies?(info["dependencies"]),
         true <- is_list(info["hot_modules"]) and Enum.all?(info["hot_modules"], &is_binary/1),
         true <- predecessors?(info["upgrade_from"], version) do
      {:ok, info}
    else
      _ -> {:error, :invalid_manifest}
    end
  end

  def select(_, _), do: {:error, :invalid_manifest}

  defp digest?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp dependencies?(values) when is_map(values),
    do: Enum.all?(values, fn {name, version} -> is_binary(name) and is_binary(version) end)

  defp dependencies?(_), do: false

  defp predecessors?(values, version) when is_list(values) and length(values) <= 32 do
    Enum.all?(values, fn
      %{"version" => from, "build_id" => build} when is_binary(from) ->
        with {:ok, %{pre: [], build: nil}} <- Version.parse(from),
             do: digest?(build) and Version.compare(from, version) == :lt,
             else: (_ -> false)

      _ ->
        false
    end)
  end

  defp predecessors?(_, _), do: false

  @doc """
  Downloads, verifies and stages a full release under the installation home.

  `offer` is what `check/1` returned. Its signed manifest is verified again
  with the pinned key before any digest in it is used; an offer without one
  is refused (`:unsigned_update`, or `:signing_key_unset` in a build without
  a key), as is one whose signature fails (`:signature_invalid`) or whose
  verified manifest does not describe it (`:offer_mismatch`). Nothing is
  downloaded or locked first.
  """
  @spec stage(offer :: map(), opts :: keyword()) :: {:ok, map()} | {:error, term()}
  def stage(offer, opts) do
    home = Keyword.fetch!(opts, :home)

    with {:ok, info} <- authenticated(offer, opts) do
      locked(home, fn ->
        directory =
          Path.join([
            home,
            "versions",
            info["version"] <> "-" <> String.slice(info["build_id"], 0, 12)
          ])

        scratch = directory <> ".staging-" <> random()
        File.mkdir_p!(Path.dirname(directory))

        with {:ok, %{type: :directory}} <- File.lstat(Path.dirname(directory)),
             :ok <- File.mkdir(scratch) do
          archive = Path.join(scratch, "download.tar.gz")

          try do
            with :ok <- download(info, archive, opts),
                 true <- file_digest(archive) == info["sha256"],
                 :ok <- Archive.validate(archive),
                 :ok <-
                   :erl_tar.extract(to_charlist(archive), [:compressed, cwd: to_charlist(scratch)]),
                 {:ok, packaged} <- Release.read(scratch, info["version"]),
                 true <- Map.drop(info, ["sha256"]) == packaged,
                 :ok <- File.rm(archive),
                 {:ok, payload} <- Payload.fingerprint(scratch),
                 :ok <- publish_stage(scratch, directory, packaged, payload) do
              {:ok, %{info: info, directory: directory, payload: payload}}
            else
              false -> {:error, :release_integrity}
              error -> error
            end
          after
            File.rm_rf(scratch)
          end
        end
      end)
    end
  end

  defp publish_stage(scratch, directory, info, payload) do
    if File.lstat(directory) != {:error, :enoent} do
      with {:ok, existing} <- Release.read(directory, info["version"]),
           true <- existing == info,
           {:ok, ^payload} <- Payload.fingerprint(directory),
           do: :ok,
           else: (_ -> {:error, :version_directory_conflict})
    else
      File.rename(scratch, directory)
    end
  end

  defp download(info, path, opts) do
    url = @origin <> "/download/v#{info["version"]}/lmx_#{info["target"]}.tar.gz"
    get = Keyword.get(opts, :get, &Req.get/2)
    {:ok, file} = File.open(path, [:write, :binary, :exclusive])
    started = System.monotonic_time(:millisecond)

    into = fn {:data, data}, {request, response} ->
      bytes = Map.get(response.private, :lmx_bytes, 0) + byte_size(data)

      if bytes > @max_download or System.monotonic_time(:millisecond) - started > 120_000,
        do: raise("release download exceeds limit")

      :ok = IO.binwrite(file, data)
      {:cont, {request, Req.Response.put_private(response, :lmx_bytes, bytes)}}
    end

    try do
      case request(
             get,
             url,
             Keyword.merge(request_options(), into: into, receive_timeout: 30_000),
             min(Keyword.get(opts, :request_timeout, 120_000), 120_000)
           ) do
        {:ok, %{status: 200}} -> :ok
        _ -> {:error, :download_failed}
      end
    rescue
      _ -> {:error, :download_failed}
    after
      File.close(file)
    end
  end

  defp request(get, url, opts, timeout) do
    # Socket receive timeouts reset with each chunk. A task deadline also bounds
    # headers and slow trickles, while the caller still closes files and locks.
    task =
      Task.Supervisor.async_nolink(Lmx.Tasks, fn ->
        try do
          get.(url, opts)
        rescue
          _ -> {:error, :request_failed}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, result} -> result
      _ -> {:error, :request_timeout}
    end
  end

  @doc "Activates an idle TUI's staged release, or selects it for the next launch."
  @spec activate(staged :: map(), tui :: pid(), opts :: keyword()) ::
          {:ok, :hot | :restart} | {:error, term()}
  def activate(%{info: info, directory: directory, payload: payload}, tui, opts) do
    locked(Keyword.fetch!(opts, :home), fn ->
      home = Keyword.fetch!(opts, :home)

      with :ok <- verify_stage(directory, info, payload, home),
           false <- File.exists?(Path.join([home, "failed-updates", info["build_id"]])),
           {:ok, installed} <- Release.current(Path.join(home, "current")),
           :ok <- newer_selection(info, installed),
           {:ok, current} <- Release.read(Keyword.fetch!(opts, :root), Lemieux.version()) do
        if hot?(current, info) and not opts[:extensions?] and active_leases(opts[:home]) <= 1 and
             Callbacks.safe?(tui, Map.get(info, "hot_modules", [])) do
          hot_install(directory, info, tui, opts)
        else
          with :ok <- point_current(opts[:home], directory), do: {:ok, :restart}
        end
      else
        true -> {:error, :quarantined_update}
        error -> error
      end
    end)
  end

  defp verify_stage(directory, info, payload, home) do
    with true <- Path.dirname(Path.expand(directory)) == Path.join(Path.expand(home), "versions"),
         {:ok, %{type: :directory}} <- File.lstat(Path.dirname(directory)),
         {:ok, ^payload} <- Payload.fingerprint(directory),
         {:ok, packaged} <- Release.read(directory, info["version"]),
         true <- packaged == Map.drop(info, ["sha256"]) do
      :ok
    else
      _ -> {:error, :release_integrity}
    end
  end

  defp newer_selection(info, installed) do
    case Version.compare(info["version"], installed["version"]) do
      :gt ->
        :ok

      :eq ->
        if info["build_id"] == installed["build_id"], do: :ok, else: {:error, :superseded_update}

      :lt ->
        {:error, :superseded_update}
    end
  end

  @doc "An exact declared predecessor with identical native/runtime dependencies is hot eligible."
  @spec hot?(current :: map(), next :: map()) :: boolean()
  def hot?(current, next) do
    Release.compatible?(current, next) and
      %{"version" => current["version"], "build_id" => current["build_id"]} in Map.get(
        next,
        "upgrade_from",
        []
      )
  end

  defp hot_install(directory, info, tui, opts) do
    root = opts[:root]
    version = info["version"]
    old = Lemieux.version() |> to_charlist()
    new = to_charlist(version)

    with :ok <- copy_version(directory, root, version),
         {:ok, ^new} <-
           :release_handler.set_unpacked(
             to_charlist(Path.join([root, "releases", version, "lmx.rel"])),
             []
           ),
         :ok <- generate_config(root, version),
         {:ok, _, _} <- :release_handler.check_install_release(new) do
      # Allocate the failure guard before replacing code. Disk-full or a VM
      # crash must not prevent rollback or let a retry select an unproven build.
      marker = Path.join([opts[:home], "failed-updates", info["build_id"]])

      with :ok <- File.mkdir_p(Path.dirname(marker)),
           :ok <- File.write(marker, "live activation did not complete", [:exclusive]),
           {:ok, _, _} <- :release_handler.install_release(new) do
        if health_passed?(Keyword.get(opts, :health, &healthy?/2), tui, version) do
          # The next launch uses the complete, pristine candidate. The running
          # root remains an OTP workspace and is never reused as a staged archive.
          case point_current(opts[:home], directory) do
            :ok ->
              File.rm(marker)

              case :release_handler.make_permanent(new) do
                :ok -> {:ok, :hot}
                _ -> {:ok, :restart}
              end

            error ->
              rollback(old, error)
          end
        else
          rollback(old, :health_failed)
        end
      end
    else
      # Execution of old code can prevent soft purge on a second upgrade. Preflight and
      # copy errors must not strand a verified update in an unretryable state.
      _error -> with :ok <- point_current(opts[:home], directory), do: {:ok, :restart}
    end
  end

  defp health_passed?(health, tui, version) do
    health.(tui, version) == true
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defp rollback(old, reason) do
    case :release_handler.install_release(old) do
      {:ok, _, _} -> {:error, {:rolled_back, reason}}
      error -> {:error, {:rollback_failed, error}}
    end
  end

  defp copy_version(directory, root, version) do
    paths = ["lib/lemieux-#{version}", "lib/lmx-#{version}", "releases/#{version}"]

    Enum.reduce_while(paths, :ok, fn path, :ok ->
      destination = Path.join(root, path)

      if File.exists?(destination) do
        {:halt, {:error, :already_unpacked}}
      else
        temporary = destination <> ".copy-" <> random()

        try do
          with {:ok, _} <- File.cp_r(Path.join(directory, path), temporary),
               :ok <- File.rename(temporary, destination),
               do: {:cont, :ok},
               else: (error -> {:halt, error})
        after
          File.rm_rf(temporary)
        end
      end
    end)
  end

  defp generate_config(root, version) do
    # Castle 1.x resolves providers in the target release's own VM. The
    # updater owns activation and rollback under its install lock, so use the
    # configuration seam without delegating those decisions to Castle.install/1.
    with {:ok, []} <- Castle.Commands.materialise(Path.join([root, "releases", version])),
         do: :ok
  end

  defp healthy?(tui, version) do
    before = ExRatatui.Runtime.snapshot(tui).render_count
    send(tui, {:version_notice, "Lemieux v#{version} loaded; checking the screen"})
    health_frame(tui, version, before, 50)
  catch
    :exit, _ -> false
  end

  defp health_frame(_tui, _version, _before, 0), do: false

  defp health_frame(tui, version, before, remaining) do
    Process.sleep(100)

    if Lemieux.version() == version and ExRatatui.Runtime.snapshot(tui).render_count > before,
      do: true,
      else: health_frame(tui, version, before, remaining - 1)
  end

  @doc "Atomically selects a staged directory for the next Unix launch."
  @spec point_current(home :: Path.t(), directory :: Path.t()) :: :ok | {:error, term()}
  def point_current(home, directory) do
    temporary = Path.join(home, ".current-" <> random())

    try do
      with :ok <- File.ln_s(directory, temporary),
           do: File.rename(temporary, Path.join(home, "current"))
    after
      File.rm(temporary)
    end
  end

  @doc "Records this CLI process so concurrent sessions cannot hot install shared files."
  @spec lease() :: Path.t() | nil
  def lease do
    if home = System.get_env("LMX_INSTALL_HOME") do
      # Transfer the launch lease to the VM under the lock. SIGKILL of the
      # launcher must not make its still-running child invisible to activation.
      if path = System.get_env("LMX_LEASE_FILE") do
        case locked(home, fn ->
               File.write!(path, System.pid())
               nil
             end) do
          nil -> nil
          error -> raise "cannot register CLI launch: #{inspect(error)}"
        end
      else
        case locked(home, fn ->
               directory = Path.join(home, "running")
               File.mkdir_p!(directory)
               path = Path.join(directory, System.pid() <> "-" <> random())
               File.write!(path, System.pid(), [:exclusive])
               path
             end) do
          path when is_binary(path) -> path
          error -> raise "cannot register CLI launch: #{inspect(error)}"
        end
      end
    end
  end

  @doc "Drops a completed CLI's lease."
  @spec release_lease(path :: Path.t() | nil) :: :ok
  def release_lease(nil), do: :ok

  def release_lease(path) do
    File.rm(path)
    :ok
  end

  defp active_leases(home),
    do: Path.wildcard(Path.join(home, "running/*")) |> Enum.count(&alive_file?/1)

  defp alive_file?(path) do
    with {:ok, pid} <- File.read(path), true <- Regex.match?(~r/\A[0-9]+\z/, pid) do
      {_output, code} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
      code == 0
    else
      _ -> false
    end
  end

  defp locked(home, fun) do
    File.mkdir_p!(home)
    path = Path.join(home, ".update-lock")
    reclaim_lock(path)

    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        IO.write(file, System.pid())

        try do
          fun.()
        after
          File.close(file)
          File.rm(path)
        end

      {:error, :eexist} ->
        {:error, :update_in_progress}

      error ->
        error
    end
  end

  defp reclaim_lock(path) do
    snapshot = path <> ".recovery"

    if File.ln(path, snapshot) == :ok do
      try do
        with {:ok, pid} <- File.read(snapshot),
             true <- Regex.match?(~r/\A[0-9]+\z/, pid),
             false <- alive_file?(snapshot),
             {:ok, locked} <- File.stat(path),
             {:ok, captured} <- File.stat(snapshot),
             true <- locked.inode == captured.inode do
          File.rm(path)
        end
      after
        File.rm(snapshot)
      end
    end
  end

  defp file_digest(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp random, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)

  defp request_options,
    do: [
      decode_body: false,
      retry: false,
      connect_options: [timeout: 2_000],
      receive_timeout: 5_000,
      headers: [{"user-agent", "lemieux/#{Lemieux.version()}"}]
    ]
end
