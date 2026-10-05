defmodule Lmx.Update.Payload do
  @moduledoc """
  Fingerprints a fresh extracted payload, including hidden files and executable
  permissions. Traversal uses lstat at every level: a symlinked parent must not
  turn a verified file into an unverified file between staging and activation.
  The expected fingerprint travels in the staging result, outside the payload.

  A file's mode enters the fingerprint as `canonical_mode/1` gives it, not as
  it is on disk, because the two extractors that make version directories
  disagree about modes, and each reuses a directory the other made only when
  the fingerprints match.
  """
  import Bitwise

  @doc "Inventories only directories and regular files without following links."
  @spec fingerprint(root :: Path.t()) :: {:ok, list()} | {:error, term()}
  def fingerprint(root) do
    with {:ok, %{type: :directory}} <- File.lstat(root), do: walk(root, "")
  end

  @doc """
  The mode a regular file with archive mode `mode` gets from every extractor
  of an lmx archive, and the mode `Lmx.Release.normalize_modes/1` packs it
  with.

  `install.py` extracts with Python's `tarfile` "data" filter where it exists
  (Python 3.12 and later, and the security releases of 3.8 to 3.11). That
  filter keeps `0o755` of a file's mode, adds owner read and write, and drops
  group and other execute when the owner has none. `:erl_tar`, which
  `Lmx.Update.stage/2` uses, and Python without the filter keep the archive's
  mode exactly. Sixteen files arrive from their Hex packages as 0664 (jsv's
  and texture's grammars, ex_ratatui's templates, typesafe_api_sdk's
  sources), so with `mode &&& 0o777` in the fingerprint a version the
  updater had staged was refused by `install.sh --replace` with "existing
  version directory differs from verified archive", which reads like
  tampering, and the updater answered a version `install.py` had made with
  `:version_directory_conflict` on every hourly check. Applying the filter's
  rule here makes both extractions of one archive fingerprint the same; it
  is idempotent, so a mode already in this form is unchanged.
  """
  @spec canonical_mode(mode :: non_neg_integer()) :: non_neg_integer()
  def canonical_mode(mode) when is_integer(mode) and mode >= 0 do
    kept = mode &&& 0o755
    kept = if (kept &&& 0o100) == 0, do: kept &&& bnot(0o111), else: kept
    kept ||| 0o600
  end

  defp walk(root, relative) do
    with {:ok, names} <- File.ls(Path.join(root, relative)) do
      names
      |> Enum.sort()
      |> Enum.reduce_while({:ok, []}, fn name, {:ok, entries} ->
        path = Path.join(relative, name)

        case entry(root, path) do
          {:ok, next} -> {:cont, {:ok, entries ++ next}}
          error -> {:halt, error}
        end
      end)
    end
  end

  defp entry(root, path) do
    with {:ok, stat} <- File.lstat(Path.join(root, path)) do
      case stat.type do
        :directory ->
          with {:ok, children} <- walk(root, path), do: {:ok, [{path, :directory} | children]}

        :regular ->
          with {:ok, bytes} <- File.read(Path.join(root, path)),
               do: {:ok, [{path, :crypto.hash(:sha256, bytes), canonical_mode(stat.mode)}]}

        _ ->
          {:error, :unsafe_payload}
      end
    end
  end
end
