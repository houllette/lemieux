defmodule Lemieux.Benchmark.SecretFiles do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  Which files stay out of a benchmark fixture because of their names.

  A fixture is a copy of somebody's workspace, and the way into a corpus is a
  copy as well: `Lemieux.Feedback.CaseDraft.create/4` freezes a workspace into
  a draft, and `Lemieux.Benchmark.Corpus.Promote.promote/3` copies the draft
  beside a manifest that is meant to be committed. A corpus also has to
  re-include dotfiles its repository would otherwise ignore, because a
  fixture's `.gitignore` or `.formatter.exs` is the case's content. So nothing
  between a person's `.env` and a public commit would stop it except a
  reviewer remembering to look.

  This is the check that does not rely on remembering. It is a name rule, not
  a scanner: a key pasted into `config.exs` passes it, which is what the
  review a draft asks for is still for. What it catches is the files whose
  whole purpose is to hold credentials:

    * `.env` and `.env.*`, except `.env.example`, the same exception the
      repository's own `.gitignore` makes, and `.envrc`;
    * `mise.local.toml` and `.mise.local.toml`, where mise keeps local
      environment overrides;
    * private keys and certificate bundles: `*.pem`, `*.key`, `*.p8`,
      `*.p12`, `*.pfx`, `*.ppk`, `*.jks`, `*.keystore`, and SSH identities
      named `id_rsa`, `id_dsa`, `id_ecdsa` or `id_ed25519` (with any suffix);
    * credential stores: `.netrc`, `_netrc`, `.npmrc`, `.pypirc`, `.pgpass`,
      `.git-credentials`, the AWS shared `credentials` file, any `.json`
      whose name contains `credentials` (gcloud's
      `application_default_credentials.json` among them) or a service
      account (`serviceAccountKey.json`, `*service-account*.json`), and
      `client_secret*.json`;
    * `*.secret.exs`, the Phoenix convention for a secrets config, and
      `erl_crash.dump`, which can hold whatever was in a crashed node's memory.

  Names are compared without regard to case, because the default macOS file
  system does not regard it either.
  """

  @exact ~w(.envrc mise.local.toml .mise.local.toml .netrc _netrc .npmrc .pypirc .pgpass
            .git-credentials credentials erl_crash.dump)

  @kept ~w(.env.example)

  @suffixes ~w(.pem .key .p8 .p12 .pfx .ppk .jks .keystore .secret.exs)

  @patterns [
    ~r/\A\.env(\..+)?\z/,
    ~r/\Aid_(rsa|dsa|ecdsa|ed25519)/,
    ~r/credentials.*\.json\z/,
    ~r/service[-_]?account.*\.json\z/,
    ~r/\Aclient_secret.*\.json\z/
  ]

  @doc """
  Whether a file with `path`'s name is one this module keeps out of fixtures.

  Only the last segment is read, so the answer is the same wherever the file
  sits.
  """
  @spec secret?(path :: Path.t()) :: boolean()
  def secret?(path) when is_binary(path) do
    name = path |> Path.basename() |> String.downcase()

    name not in @kept and
      (name in @exact or String.ends_with?(name, @suffixes) or
         Enum.any?(@patterns, &Regex.match?(&1, name)))
  end

  @doc """
  The secret-shaped files under `dir`, relative to it and sorted.

  Directories are walked, symlinks are judged by their own name and never
  followed, so a link cannot lead the walk out of the fixture.
  """
  @spec find(dir :: Path.t()) :: [Path.t()]
  def find(dir) when is_binary(dir) do
    dir |> walk("", []) |> Enum.filter(&secret?/1) |> Enum.sort()
  end

  @doc """
  Copies the tree at `source` to `destination`, leaving out secret-shaped
  files, and returns the relative paths it left out, sorted.

  Everything else is copied as `File.cp_r/3` copies it: file modes kept,
  symlinks recreated rather than followed. `destination` must not exist yet.
  """
  @spec copy(source :: Path.t(), destination :: Path.t()) ::
          {:ok, skipped :: [Path.t()]} | {:error, term()}
  def copy(source, destination) when is_binary(source) and is_binary(destination) do
    with :ok <- absent(destination),
         :ok <- File.mkdir_p(destination),
         {:ok, skipped} <- copy_entries(source, destination, "", []) do
      {:ok, Enum.sort(skipped)}
    end
  end

  defp absent(path),
    do: if(File.exists?(path), do: {:error, {:destination_exists, path}}, else: :ok)

  defp copy_entries(source, destination, relative, skipped) do
    case File.ls(Path.join(source, relative)) do
      {:ok, names} ->
        Enum.reduce_while(
          names,
          {:ok, skipped},
          &copy_next(source, destination, relative, &1, &2)
        )

      {:error, reason} ->
        {:error, {:copy_fixture, Path.join(source, relative), reason}}
    end
  end

  defp copy_next(source, destination, relative, name, {:ok, skipped}) do
    case copy_entry(source, destination, Path.join(relative, name), skipped) do
      {:ok, skipped} -> {:cont, {:ok, skipped}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp copy_entry(source, destination, relative, skipped) do
    from = Path.join(source, relative)
    to = Path.join(destination, relative)

    case File.lstat(from) do
      {:ok, %File.Stat{type: :directory}} ->
        with :ok <- File.mkdir_p(to), do: copy_entries(source, destination, relative, skipped)

      {:ok, _file_or_link} ->
        if secret?(relative), do: {:ok, [relative | skipped]}, else: copy_file(from, to, skipped)

      {:error, reason} ->
        {:error, {:copy_fixture, from, reason}}
    end
  end

  defp copy_file(from, to, skipped) do
    case File.cp_r(from, to) do
      {:ok, _copied} -> {:ok, skipped}
      {:error, reason, path} -> {:error, {:copy_fixture, path, reason}}
    end
  end

  defp walk(dir, relative, found) do
    case File.ls(Path.join(dir, relative)) do
      {:ok, names} -> Enum.reduce(names, found, &visit(dir, Path.join(relative, &1), &2))
      {:error, _reason} -> found
    end
  end

  defp visit(dir, path, found) do
    case File.lstat(Path.join(dir, path)) do
      {:ok, %File.Stat{type: :directory}} -> walk(dir, path, found)
      {:ok, _file_or_link} -> [path | found]
      {:error, _reason} -> found
    end
  end
end
