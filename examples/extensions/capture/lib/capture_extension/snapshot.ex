defmodule CaptureExtension.Snapshot do
  @moduledoc """
  A bounded copy of a workspace, and a record of what was left out.

  `Lemieux.Feedback.CaseDraft` copies whatever directory it is given, which
  is right for a curated source and wrong for a working checkout: `_build`,
  `deps`, `node_modules` and a `.git` object store would make every draft
  hundreds of megabytes, and one stray core dump would make it a gigabyte.
  This module copies the workspace into a staging directory first, applying
  the limits, so the draft that reaches `CaseDraft` is already bounded.

  Nothing is silently dropped. Every skipped path is returned with a reason
  (`skipped_directory`, `excluded`, `secret`, `too_large`, `over_budget`,
  `symlink`, `special`) so the draft can record it and a reviewer can decide
  whether the fixture is still a faithful reproduction. Symlinks are never
  followed: a link out of the workspace would otherwise pull the target in.

  Files whose names say they hold credentials (`secret?/1`) are never
  copied, nor is `lmx`'s own `.lmx/config.json`, where it saves provider
  keys, which a session started in the home directory would otherwise take
  along. A draft is a step towards a corpus case, and a corpus is committed:
  a `.env` or a private key copied here is one `git add` away from a
  repository, and a secret scanner only catches the values that match its
  rules. Leaving one out can make a fixture incomplete, which is what the
  `secret` record beside it is for; including one cannot be undone once it
  is pushed.

  The name rule is the one Lemieux applies when it copies a workspace into a
  feedback draft or a corpus fixture (`Lemieux.Benchmark.SecretFiles`), kept
  here because that module is newer than the Lemieux this example pins.
  Once the pin moves past it, call it instead of keeping a second list: two
  lists drift, and a correction draft is copied by this module alone.
  """

  import Bitwise, only: [band: 2]

  # The documented template, the one `.env*` a repository's own `.gitignore`
  # conventionally lets through.
  @kept ~w(.env.example)
  @secret_names ~w(.env .envrc mise.local.toml .mise.local.toml .netrc _netrc .npmrc .pypirc
                   .pgpass .git-credentials credentials erl_crash.dump)
  @secret_prefixes ~w(.env. id_rsa id_dsa id_ecdsa id_ed25519)
  @secret_suffixes ~w(.pem .key .p8 .p12 .pfx .ppk .jks .keystore .secret.exs)
  @service_accounts ~w(serviceaccount service-account service_account)

  @typedoc "A JSON-shaped summary of the copy."
  @type summary :: %{required(String.t()) => term()}

  @doc """
  Copies `source` into `destination`, which must not exist yet.

  Options: `:max_file_bytes`, `:max_total_bytes`, `:skip_dirs` (directory
  names skipped at any depth), `:exclude` (absolute directories skipped
  wherever they fall, for a drafts directory that lives inside the
  workspace it snapshots) and `:skip_secrets` (default `true`; `false` is
  for a curated tree known to hold no credentials).
  """
  @spec copy(source :: Path.t(), destination :: Path.t(), opts :: keyword()) ::
          {:ok, summary()} | {:error, term()}
  def copy(source, destination, opts) when is_binary(source) and is_binary(destination) do
    source = Path.expand(source)
    destination = Path.expand(destination)

    limits = %{
      max_file: Keyword.get(opts, :max_file_bytes, 1_048_576),
      max_total: Keyword.get(opts, :max_total_bytes, 16 * 1_048_576),
      skip_dirs:
        MapSet.new(Keyword.get(opts, :skip_dirs, [".git", "_build", "deps", "node_modules"])),
      exclude: opts |> Keyword.get(:exclude, []) |> Enum.map(&Path.expand/1) |> MapSet.new(),
      skip_secrets: Keyword.get(opts, :skip_secrets, true)
    }

    with :ok <- directory(source),
         :ok <- unused(destination),
         :ok <- File.mkdir_p(destination),
         {:ok, acc} <- walk("", source, destination, limits, new_acc()) do
      {:ok, summarise(acc)}
    end
  end

  @doc """
  Whether a file with `path`'s name usually holds credentials. Only the last
  segment is read, and without regard to case, because the default macOS
  file system does not regard it either:

    * `.env` and `.env.*`, except the `.env.example` template, and `.envrc`;
    * `mise.local.toml` and `.mise.local.toml`, mise's local overrides;
    * private keys and certificate bundles: `*.pem`, `*.key`, `*.p8`,
      `*.p12`, `*.pfx`, `*.ppk`, `*.jks`, `*.keystore`, and SSH identities
      (`id_rsa*`, `id_dsa*`, `id_ecdsa*`, `id_ed25519*`);
    * credential stores: `.netrc`, `_netrc`, `.npmrc`, `.pypirc`, `.pgpass`,
      `.git-credentials`, the AWS shared `credentials` file, any `.json`
      whose name contains `credentials` or names a service account, and
      `client_secret*.json`;
    * `*.secret.exs`, and `erl_crash.dump`, whose memory image can hold
      anything the crashed node knew.
  """
  @spec secret?(path :: Path.t()) :: boolean()
  def secret?(path) when is_binary(path) do
    name = path |> Path.basename() |> String.downcase()
    name not in @kept and (named_secret?(name) or secret_json?(name))
  end

  defp named_secret?(name) do
    name in @secret_names or String.starts_with?(name, @secret_prefixes) or
      String.ends_with?(name, @secret_suffixes)
  end

  defp secret_json?(name) do
    String.ends_with?(name, ".json") and
      (String.contains?(name, ["credentials" | @service_accounts]) or
         String.starts_with?(name, "client_secret"))
  end

  defp new_acc, do: %{files: 0, bytes: 0, skipped: [], digests: []}

  defp walk(relative, source, destination, limits, acc) do
    case File.ls(Path.join(source, relative)) do
      {:ok, names} -> walk_names(Enum.sort(names), relative, source, destination, limits, acc)
      {:error, reason} -> {:error, {:snapshot_list, relative, reason}}
    end
  end

  # Sorted, so the same workspace always copies in the same order and the
  # total-bytes budget always falls on the same file.
  defp walk_names(names, relative, source, destination, limits, acc) do
    Enum.reduce_while(names, {:ok, acc}, fn name, {:ok, acc} ->
      case visit(join(relative, name), source, destination, limits, acc) do
        {:ok, acc} -> {:cont, {:ok, acc}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp visit(path, source, destination, limits, acc) do
    full = Path.join(source, path)

    case File.lstat(full) do
      {:ok, %File.Stat{type: :directory}} ->
        visit_directory(path, source, destination, limits, acc)

      {:ok, %File.Stat{type: :regular} = stat} ->
        visit_file(path, stat, source, destination, limits, acc)

      {:ok, %File.Stat{type: :symlink}} ->
        {:ok, skip(acc, path, "symlink", nil)}

      {:ok, %File.Stat{}} ->
        {:ok, skip(acc, path, "special", nil)}

      {:error, reason} ->
        {:error, {:snapshot_stat, path, reason}}
    end
  end

  defp visit_directory(path, source, destination, limits, acc) do
    cond do
      MapSet.member?(limits.exclude, Path.join(source, path)) ->
        {:ok, skip(acc, path, "excluded", nil)}

      MapSet.member?(limits.skip_dirs, Path.basename(path)) ->
        {:ok, skip(acc, path, "skipped_directory", nil)}

      true ->
        case File.mkdir_p(Path.join(destination, path)) do
          :ok -> walk(path, source, destination, limits, acc)
          {:error, reason} -> {:error, {:snapshot_mkdir, path, reason}}
        end
    end
  end

  defp visit_file(path, %File.Stat{size: size, mode: mode}, source, destination, limits, acc) do
    cond do
      secret_path?(path, limits) -> {:ok, skip(acc, path, "secret", nil)}
      size > limits.max_file -> {:ok, skip(acc, path, "too_large", size)}
      acc.bytes + size > limits.max_total -> {:ok, skip(acc, path, "over_budget", size)}
      true -> copy_file(path, mode, source, destination, acc)
    end
  end

  defp secret_path?(path, %{skip_secrets: true}), do: secret?(path) or lmx_config?(path)
  defp secret_path?(_path, _limits), do: false

  defp lmx_config?(path) do
    last_two = path |> String.downcase() |> Path.split() |> Enum.take(-2)
    last_two == [".lmx", "config.json"]
  end

  defp copy_file(path, mode, source, destination, acc) do
    target = Path.join(destination, path)

    with {:ok, contents} <- read(path, Path.join(source, path)),
         :ok <- write(path, target, contents),
         :ok <- chmod(path, target, mode) do
      {:ok,
       %{
         acc
         | files: acc.files + 1,
           bytes: acc.bytes + byte_size(contents),
           digests: [{path, :crypto.hash(:sha256, contents)} | acc.digests]
       }}
    end
  end

  defp read(path, full) do
    case File.read(full) do
      {:ok, contents} -> {:ok, contents}
      {:error, reason} -> {:error, {:snapshot_read, path, reason}}
    end
  end

  defp write(path, target, contents) do
    case File.write(target, contents) do
      :ok -> :ok
      {:error, reason} -> {:error, {:snapshot_write, path, reason}}
    end
  end

  # Permission bits only: a fixture that lost its executable bit would make a
  # `sh tests/run.sh` verifier pass for the wrong reason, or fail for one.
  defp chmod(path, target, mode) do
    case File.chmod(target, band(mode, 0o777)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:snapshot_chmod, path, reason}}
    end
  end

  defp skip(acc, path, reason, bytes) do
    entry = %{"path" => path, "reason" => reason}
    entry = if is_integer(bytes), do: Map.put(entry, "bytes", bytes), else: entry

    %{acc | skipped: [entry | acc.skipped]}
  end

  defp summarise(acc) do
    digest =
      acc.digests
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {path, digest} -> [path, 0, digest] end)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    %{
      "files" => acc.files,
      "bytes" => acc.bytes,
      "skipped" => Enum.reverse(acc.skipped),
      "digest" => digest
    }
  end

  defp join("", name), do: name
  defp join(relative, name), do: Path.join(relative, name)

  defp directory(path),
    do: if(File.dir?(path), do: :ok, else: {:error, {:source_not_directory, path}})

  defp unused(path),
    do: if(File.exists?(path), do: {:error, {:destination_exists, path}}, else: :ok)
end
