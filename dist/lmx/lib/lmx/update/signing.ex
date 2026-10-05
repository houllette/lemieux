defmodule Lmx.Update.Signing do
  @moduledoc """
  The maintainer's side of release signing: creating the key, signing release
  assets, checking signatures and signing a draft release. The Mix tasks
  `lmx.release.keygen`, `lmx.release.sign`, `lmx.release.verify` and
  `lmx.release.sign_draft` are thin wrappers; this module takes explicit paths
  and a `gh` runner so tests can drive it with throwaway keys and no network.

  The private key never passes through CI, the repository or a terminal.
  `keygen/2` writes it to a file only its owner can read and never prints it,
  every function here reads it only to sign, and nothing here can publish a
  release: release CI builds an unsigned draft, `sign_draft/3` adds the two
  signatures to it, and the maintainer publishes it by hand. A signing step in
  CI would put the key where a compromised workflow or token could use it,
  which is the attack the signatures exist to stop.

  Nor is the key ever written to or read from a Git working tree
  (`outside_checkout/1`). Run from `dist/lmx`, `--private-key release.key`
  would otherwise land in the checkout, untracked and unignored, where the
  next `git add -A` stages it and a push publishes the one key every
  installed `lmx` trusts. An ignore rule would only trade that for `git clean
  -fdx`, which deletes ignored files and with them the only copy of the key.

  The private key file holds the standard padded base64 of the raw 32-byte
  Ed25519 private key on one line, after optional `#` comment lines. Public
  key and signature formats are those of `Lmx.Update.Signature`.
  """

  alias Lmx.Update.Signature

  @repo "houllette/lemieux"
  @installer_line ~r/^RELEASE_PUBLIC_KEY = "[^"\n]*"$/m
  @tag ~r/\Av((0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*))\z/
  @signed ~w(SHA256SUMS update.json)

  @typedoc "Runs `gh` with `args` and returns its combined output and exit status."
  @type runner :: (args :: [String.t()] -> {String.t(), non_neg_integer()})

  @typedoc "What `release-signing.pub` pins: a public key, or nothing yet."
  @type pinned :: {:ok, Signature.public_key()} | :unset

  @doc """
  Creates a key pair. The private key goes to `path` (mode 0600, never
  overwritten, never printed, never inside a Git checkout); the public key
  replaces the contents of `:public_key_file` and the `RELEASE_PUBLIC_KEY`
  line of `:installer`.

  A pinned key is replaced only with `rotate?: true`: installed builds trust
  the key they were compiled with and reject everything signed by a new one,
  so a rotation has to reach them in a release signed with the old key.
  Returns the encoded public key.
  """
  @spec keygen(path :: Path.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def keygen(path, opts) do
    public_key_file = Keyword.fetch!(opts, :public_key_file)
    installer = Keyword.fetch!(opts, :installer)

    with :ok <- absent(path),
         :ok <- outside_checkout(path),
         {:ok, pinned} <- read_pinned(public_key_file),
         :ok <- replaceable(pinned, public_key_file, Keyword.get(opts, :rotate?, false)),
         {:ok, script} <- read_installer(installer),
         {public, private} = :crypto.generate_key(:eddsa, :ed25519),
         encoded = Signature.encode_public_key(public),
         :ok <- write_private_key(path, private),
         :ok <- replace_file(public_key_file, encoded <> "\n"),
         :ok <- replace_file(installer, pin_installer(script, encoded)) do
      {:ok, encoded}
    end
  end

  @doc "Reads `release-signing.pub`."
  @spec read_pinned(path :: Path.t()) :: {:ok, pinned()} | {:error, String.t()}
  def read_pinned(path) do
    with {:ok, text} <- read(path), do: pinned_from(Signature.parse_public_key(text), path)
  end

  defp pinned_from({:error, :invalid_public_key}, path),
    do: {:error, "#{path} holds neither UNSET nor a base64 Ed25519 public key"}

  defp pinned_from(pinned, _path), do: {:ok, pinned}

  @doc "Parses a `--public-key` argument (base64, as in `release-signing.pub`)."
  @spec parse_public_key(text :: String.t()) ::
          {:ok, Signature.public_key()} | {:error, String.t()}
  def parse_public_key(text) do
    case Signature.parse_public_key(text) do
      {:ok, key} -> {:ok, key}
      _unset_or_invalid -> {:error, "--public-key must be the base64 of a 32-byte Ed25519 key"}
    end
  end

  @doc "The public key pinned in an installer's `RELEASE_PUBLIC_KEY` line, as written."
  @spec installer_key(script :: String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def installer_key(script) do
    case Regex.scan(@installer_line, script) do
      [[line]] ->
        [_, value] = Regex.run(~r/"([^"\n]*)"/, line)
        {:ok, value}

      _none_or_several ->
        {:error, "the installer must contain exactly one RELEASE_PUBLIC_KEY line"}
    end
  end

  @doc """
  Reads a private key file, refusing one inside a Git checkout (see
  `outside_checkout/1`). Errors never include the file's contents.
  """
  @spec read_private_key(path :: Path.t()) ::
          {:ok, Signature.private_key()} | {:error, String.t()}
  def read_private_key(path) do
    with :ok <- outside_checkout(path),
         {:ok, text} <- read(path),
         [encoded] <- key_lines(text),
         {:ok, <<_::binary-size(32)>> = key} <- Base.decode64(encoded) do
      {:ok, key}
    else
      {:error, message} when is_binary(message) -> {:error, message}
      _invalid -> {:error, "#{path} is not an lmx release-signing private key"}
    end
  end

  defp key_lines(text) do
    text
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
  end

  @doc """
  Refuses a private-key path inside a Git working tree: any directory from
  the key's own up to `/` that holds a `.git` directory or file (a worktree).
  The path is taken as given, without resolving symbolic links.
  """
  @spec outside_checkout(path :: Path.t()) :: :ok | {:error, String.t()}
  def outside_checkout(path) do
    case checkout_of(Path.dirname(Path.expand(path))) do
      nil ->
        :ok

      checkout ->
        {:error,
         "#{path} is inside the Git checkout #{checkout}, where one `git add -A` stages it " <>
           "and a push publishes the key every installed lmx trusts. Keep release-signing " <>
           "keys outside every repository, for example on an encrypted removable volume, " <>
           "and pass that path."}
    end
  end

  defp checkout_of(directory) do
    parent = Path.dirname(directory)

    cond do
      File.exists?(Path.join(directory, ".git")) -> directory
      parent == directory -> nil
      true -> checkout_of(parent)
    end
  end

  @doc "Whether users other than the owner may read the private key file."
  @spec exposed?(path :: Path.t()) :: boolean()
  def exposed?(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> Bitwise.band(mode, 0o077) != 0
      _unreadable -> false
    end
  end

  @doc """
  Signs each file, writing `FILE.sig` next to it, after checking that the
  private key belongs to `pinned` (the key builds trust). Every signature is
  verified before it is written.
  """
  @spec sign_files(
          files :: [Path.t()],
          private_key :: Signature.private_key(),
          pinned :: pinned()
        ) ::
          {:ok, [Path.t()]} | {:error, String.t()}
  def sign_files(files, private_key, pinned) do
    public = Signature.public_key(private_key)

    with :ok <- belongs(public, pinned),
         {:ok, written} <-
           Enum.reduce_while(files, {:ok, []}, &sign_into(&1, &2, private_key, public)) do
      {:ok, Enum.reverse(written)}
    end
  end

  defp sign_into(file, {:ok, written}, private_key, public) do
    case sign_file(file, private_key, public) do
      {:ok, signature} -> {:cont, {:ok, [signature | written]}}
      error -> {:halt, error}
    end
  end

  defp sign_file(file, private_key, public) do
    with {:ok, body} <- read(file),
         signature = Signature.sign(body, private_key),
         {:verified, :ok} <- {:verified, Signature.verify(body, signature, public)},
         :ok <- replace_file(file <> ".sig", signature) do
      {:ok, file <> ".sig"}
    else
      {:verified, _failed} -> {:error, "the signature for #{file} did not verify"}
      {:error, message} -> {:error, message}
    end
  end

  @doc "Checks every `FILE` against `FILE.sig` with `key`; reports each failure."
  @spec verify_files(files :: [Path.t()], key :: Signature.public_key()) ::
          :ok | {:error, String.t()}
  def verify_files(files, key) do
    case Enum.flat_map(files, &failure(&1, key)) do
      [] -> :ok
      failures -> {:error, Enum.join(failures, "\n")}
    end
  end

  defp failure(file, key) do
    with {:file, {:ok, body}} <- {:file, File.read(file)},
         {:sig, {:ok, signature}} <- {:sig, File.read(file <> ".sig")},
         :ok <- Signature.verify(body, signature, key) do
      []
    else
      {:file, {:error, reason}} -> ["#{file}: cannot read it (#{:file.format_error(reason)})"]
      {:sig, {:error, reason}} -> ["#{file}.sig: cannot read it (#{:file.format_error(reason)})"]
      {:error, :signature_invalid} -> ["#{file}: the signature does not verify with this key"]
    end
  end

  @doc """
  Signs a draft GitHub release in place, without publishing it.

  Downloads the draft's `SHA256SUMS`, `update.json` and `install.py`, checks
  that they belong together, signs `SHA256SUMS` and `update.json`, uploads
  the two `.sig` files, then downloads everything again and verifies it.
  Returns progress lines.

  Belonging together means: the manifest names the tag's version; the
  checksums list the manifest and installer bytes; the installer pins the
  same key; and the manifest and the checksums name the same archives with
  the same digests, each in an entry the updater accepts. `install.py`
  trusts `SHA256SUMS` and installed builds trust `update.json`, so an archive
  swapped in one of them alone would otherwise be signed into one install
  path and refused by the other.

  The signatures cannot show that the draft's assets are the tagged
  workflow run's output; the release procedure compares them with that run's
  artifact before signing.

  Options: `:pinned` (required; see `read_pinned/1`), `:repo` (default
  `#{@repo}`) and `:runner` (default: the `gh` executable).
  """
  @spec sign_draft(tag :: String.t(), private_key :: Signature.private_key(), opts :: keyword()) ::
          {:ok, [String.t()]} | {:error, String.t()}
  def sign_draft(tag, private_key, opts) do
    pinned = Keyword.fetch!(opts, :pinned)
    repo = Keyword.get(opts, :repo, @repo)
    runner = Keyword.get_lazy(opts, :runner, fn -> gh_runner() end)
    public = Signature.public_key(private_key)

    with {:ok, version} <- tag_version(tag),
         :ok <- belongs(public, pinned),
         {:ok, prerelease?} <- draft(runner, repo, tag) do
      scratch = private_directory()

      try do
        with {:ok, lines} <- signing(runner, repo, tag, version, private_key, pinned, scratch),
             do: {:ok, lines ++ prerelease_notice(prerelease?, tag)}
      after
        File.rm_rf(scratch)
      end
    end
  end

  # A draft can be marked as a pre-release (release.yml has made them so).
  # GitHub's releases/latest skips pre-releases, and install.sh and every
  # installed lmx read only that, so one published as it is reaches nobody.
  defp prerelease_notice(true, tag),
    do: [
      "Note: #{tag} is marked as a pre-release. install.sh and installed lmx read GitHub's " <>
        "releases/latest, which skips pre-releases: clear \"Set as a pre-release\" when you " <>
        "publish it, or neither will see it."
    ]

  defp prerelease_notice(false, _tag), do: []

  defp signing(runner, repo, tag, version, private_key, pinned, scratch) do
    download = Path.join(scratch, "draft")
    check = Path.join(scratch, "check")
    files = Enum.map(@signed, &Path.join(download, &1))
    File.mkdir_p!(download)
    File.mkdir_p!(check)

    with :ok <- gh(runner, download_args(tag, repo, download, @signed ++ ["install.py"])),
         :ok <- consistent(download, version, pinned),
         {:ok, signatures} <- sign_files(files, private_key, pinned),
         :ok <-
           gh(runner, ["release", "upload", tag | signatures] ++ ["--clobber", "--repo", repo]),
         names = @signed ++ Enum.map(@signed, &(&1 <> ".sig")),
         :ok <- gh(runner, download_args(tag, repo, check, names)),
         {:ok, key} <- pinned_key(pinned),
         :ok <- verify_files(Enum.map(@signed, &Path.join(check, &1)), key) do
      {:ok,
       [
         "Checked #{tag}: update.json names #{version}, its archives match SHA256SUMS, and " <>
           "SHA256SUMS lists the manifest and an installer that pins this key.",
         "Uploaded SHA256SUMS.sig and update.json.sig to the draft #{tag} in #{repo}.",
         "Downloaded them again and verified both with the pinned key.",
         "The draft is still unpublished: review it, then publish it yourself."
       ]}
    end
  end

  defp download_args(tag, repo, directory, names),
    do:
      ["release", "download", tag, "--repo", repo, "--dir", directory] ++
        Enum.flat_map(names, &["--pattern", &1])

  # Whether the release is a draft, and whether it is marked as a pre-release.
  defp draft(runner, repo, tag) do
    case runner.(["release", "view", tag, "--repo", repo, "--json", "isDraft,isPrerelease"]) do
      {output, 0} ->
        draft_state(JSON.decode(output), tag)

      {output, status} ->
        {:error, "gh release view #{tag} failed (exit #{status}): #{String.trim(output)}"}
    end
  end

  defp draft_state({:ok, %{"isDraft" => true, "isPrerelease" => prerelease?}}, _tag)
       when is_boolean(prerelease?),
       do: {:ok, prerelease?}

  defp draft_state({:ok, %{"isDraft" => false}}, tag),
    do:
      {:error,
       "#{tag} is not a draft release. sign_draft only signs drafts; for a published " <>
         "release, sign with mix lmx.release.sign and upload with gh release upload."}

  defp draft_state(_unexpected, tag),
    do: {:error, "gh release view #{tag} did not report whether the release is a draft"}

  # The signatures vouch for these bytes on every installed lmx, so check that
  # they describe the release being signed before signing anything.
  defp consistent(directory, version, pinned) do
    with {:ok, body} <- read(Path.join(directory, "update.json")),
         {:ok, sums} <- read(Path.join(directory, "SHA256SUMS")),
         {:ok, installer} <- read(Path.join(directory, "install.py")),
         {:ok, table} <- checksums(sums),
         {:ok, manifest} <- manifest(body, version),
         :ok <- archives(manifest, table),
         :ok <- listed(table, "update.json", body),
         :ok <- listed(table, "install.py", installer),
         {:ok, installer_key} <- installer_key(installer),
         {:ok, key} <- pinned_key(pinned) do
      if installer_key == Signature.encode_public_key(key),
        do: :ok,
        else:
          {:error,
           "the draft's install.py pins #{installer_key}, not the key in release-signing.pub; " <>
             "rebuild the draft from a commit that pins the release key"}
    end
  end

  defp manifest(body, version) do
    case JSON.decode(body) do
      {:ok, %{"version" => ^version, "targets" => targets} = manifest} when is_map(targets) ->
        {:ok, manifest}

      {:ok, %{"version" => ^version}} ->
        {:error, "the draft's update.json has no targets"}

      _other ->
        {:error, "the draft's update.json does not name version #{version}"}
    end
  end

  # install.py checks an archive against SHA256SUMS and installed builds
  # check it against update.json: both must name the same archives with the
  # same digests, in entries the updater accepts.
  defp archives(%{"targets" => targets} = manifest, table) do
    named = targets |> Map.keys() |> Enum.sort()

    archived =
      for {name, _digest} <- table,
          [_, target] <- [Regex.run(~r/\Almx_(.+)\.tar\.gz\z/, name)],
          do: target

    cond do
      named == [] ->
        {:error, "the draft's update.json lists no archives"}

      named != Enum.sort(archived) ->
        {:error,
         "the draft's update.json and SHA256SUMS list different archives " <>
           "(update.json: #{Enum.join(named, ", ")}; SHA256SUMS: #{Enum.join(Enum.sort(archived), ", ")})"}

      true ->
        Enum.find_value(named, :ok, &archive_problem(manifest, table, &1))
    end
  end

  defp archive_problem(manifest, table, target) do
    archive = "lmx_#{target}.tar.gz"
    listed = Map.fetch!(table, archive)

    case Lmx.Update.select(manifest, target) do
      {:ok, %{"sha256" => ^listed}} ->
        nil

      {:ok, _entry} ->
        {:error, "the draft's update.json and SHA256SUMS give #{archive} different digests"}

      {:error, _invalid} ->
        {:error, "the draft's update.json entry for #{target} would be rejected by lmx's updater"}
    end
  end

  defp listed(table, name, body) do
    if Map.get(table, name) == sha256(body),
      do: :ok,
      else: {:error, "the draft's SHA256SUMS does not list the draft's #{name}"}
  end

  defp checksums(text) do
    text
    |> String.split("\n", trim: true)
    |> Enum.reduce_while({:ok, %{}}, fn line, {:ok, table} ->
      case Regex.run(~r/\A([0-9a-f]{64}) [ *](\S.*)\z/, line) do
        [_, digest, name] when not is_map_key(table, name) ->
          {:cont, {:ok, Map.put(table, name, digest)}}

        _invalid ->
          {:halt, {:error, "the draft's SHA256SUMS is malformed"}}
      end
    end)
  end

  defp tag_version(tag) do
    case Regex.run(@tag, tag) do
      [_, version | _] -> {:ok, version}
      nil -> {:error, "--tag must name a stable release, such as v1.2.3"}
    end
  end

  defp belongs(public, {:ok, public}), do: :ok

  defp belongs(_public, :unset),
    do:
      {:error,
       "no release-signing key is pinned (release-signing.pub is UNSET); run " <>
         "mix lmx.release.keygen first (mix lmx.release.sign --public-key signs for another key)"}

  defp belongs(_public, {:ok, _other}),
    do:
      {:error,
       "this private key does not belong to the pinned public key; " <>
         "builds would reject its signatures"}

  defp pinned_key({:ok, key}), do: {:ok, key}
  defp pinned_key(:unset), do: belongs(nil, :unset)

  defp replaceable(:unset, _path, _rotate?), do: :ok
  defp replaceable({:ok, _key}, _path, true), do: :ok

  defp replaceable({:ok, _key}, path, false),
    do:
      {:error,
       "#{path} already pins a release-signing key. Installed builds reject updates signed " <>
         "by any other key until a release signed with this one pins the new key; pass " <>
         "--rotate only as part of that planned rotation (see RELEASING.md)."}

  defp read_installer(path) do
    with {:ok, script} <- read(path),
         {:ok, _key} <- installer_key(script),
         do: {:ok, script}
  end

  defp pin_installer(script, encoded),
    do:
      Regex.replace(@installer_line, script, fn _line ->
        ~s(RELEASE_PUBLIC_KEY = "#{encoded}")
      end)

  defp absent(path) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      _exists -> {:error, "#{path} already exists; keygen never overwrites a private key"}
    end
  end

  # The key file is 0600 inside a 0700 directory before it moves into place,
  # so no other local user can open it at any moment, not even while empty:
  # an open descriptor would keep reading after a later chmod. The rename keeps
  # the inode and its mode.
  defp write_private_key(path, private) do
    staging = Path.join(Path.dirname(path), ".lmx-release-key-" <> random())

    case File.mkdir(staging) do
      :ok ->
        try do
          move_private_key(staging, path, private)
        after
          File.rm_rf(staging)
        end

      {:error, reason} ->
        {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp move_private_key(staging, path, private) do
    staged = Path.join(staging, "key")

    contents =
      "# lmx release-signing private key (Ed25519). Keep it offline; never commit, " <>
        "share or print it.\n" <> Base.encode64(private) <> "\n"

    with :ok <- File.chmod(staging, 0o700),
         :ok <- File.write(staged, "", [:exclusive]),
         :ok <- File.chmod(staged, 0o600),
         :ok <- File.write(staged, contents),
         :ok <- absent(path),
         :ok <- File.rename(staged, path) do
      :ok
    else
      {:error, message} when is_binary(message) -> {:error, message}
      {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
    end
  end

  # Writes beside the target and renames over it, keeping the target's mode,
  # so an interrupted write never leaves a truncated key or installer behind.
  defp replace_file(path, contents) do
    temporary = path <> ".tmp-" <> random()

    try do
      with :ok <- File.write(temporary, contents, [:exclusive]),
           :ok <- keep_mode(path, temporary),
           :ok <- File.rename(temporary, path) do
        :ok
      else
        {:error, reason} -> {:error, "cannot write #{path}: #{:file.format_error(reason)}"}
      end
    after
      File.rm(temporary)
    end
  end

  defp keep_mode(path, temporary) do
    case File.stat(path) do
      {:ok, %{mode: mode}} -> File.chmod(temporary, Bitwise.band(mode, 0o777))
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "cannot read #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp gh(runner, args) do
    case runner.(args) do
      {_output, 0} ->
        :ok

      {output, status} ->
        {:error,
         "gh #{Enum.join(Enum.take(args, 3), " ")} failed (exit #{status}): #{String.trim(output)}"}
    end
  end

  defp gh_runner do
    case System.find_executable("gh") do
      nil -> fn _args -> {"the GitHub CLI (gh) is not installed or not on PATH", 127} end
      gh -> &System.cmd(gh, &1, stderr_to_stdout: true)
    end
  end

  defp private_directory do
    directory = Path.join(System.tmp_dir!(), "lmx-sign-draft-" <> random())
    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    directory
  end

  defp sha256(body), do: :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
  defp random, do: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
end
