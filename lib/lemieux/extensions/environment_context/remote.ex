defmodule Lemieux.Extensions.EnvironmentContext.Remote do
  @moduledoc false

  alias Lemieux.Checkpoint.Git.Repository

  @doc "Reads only a single local origin URL as data, without includes or URL rewriting."
  @spec read(cwd :: Path.t()) :: String.t() | nil
  def read(cwd) do
    # `remote get-url` applies insteadOf rules, which can introduce credentials.
    # Multiple URLs are ambiguous, so preserve their NUL-delimited boundaries.
    arguments = ~w(config --local --no-includes --null --get-all remote.origin.url)

    with {:ok, output} <- Repository.real(cwd, arguments),
         [remote, ""] <- String.split(output, <<0>>),
         true <- String.contains?(remote, ":") do
      # A bare host/owner/repository in Git configuration is a local path,
      # even though normalize/1 also accepts already canonical identities.
      normalize(remote)
    else
      _absent_or_ambiguous -> nil
    end
  end

  @doc "Returns a conservative host/owner/repository identity without transport credentials."
  @spec normalize(remote :: term()) :: String.t() | nil
  def normalize(remote) when is_binary(remote) and byte_size(remote) <= 4_096 do
    if String.valid?(remote) and not Regex.match?(~r/[\s\x00-\x1f\x7f\\]/u, remote) do
      parse(remote)
    end
  end

  def normalize(_remote), do: nil

  defp parse(remote) do
    cond do
      String.contains?(remote, "://") -> url(remote)
      String.contains?(remote, ":") -> scp(remote)
      true -> canonical(remote)
    end
  end

  defp url(remote) do
    with {:ok, %URI{scheme: scheme, host: host, port: port, path: "/" <> path}} <- URI.new(remote),
         true <- scheme in ~w(http https ssh git),
         true <- is_nil(port) or port in 1..65_535 do
      identity(host, transport_path(path))
    else
      _invalid -> nil
    end
  end

  # A drive-relative Windows path is indistinguishable from a bare one-letter
  # SCP host. Abstain on that spelling; git@c: or ssh://c/ remains explicit.
  defp scp(<<drive, ?:, _path::binary>>) when drive in ?A..?Z or drive in ?a..?z, do: nil

  defp scp(remote) do
    case Regex.run(~r/\A(?:[a-zA-Z0-9_.-]+@)?([^:@\/]+):([^:]+)\z/, remote) do
      [_, host, path] -> identity(host, transport_path(path))
      _invalid -> nil
    end
  end

  # Canonical identities can themselves name a repository ending in `.git`.
  # Strip that suffix only while crossing from a transport URL, never again
  # when an already sanitized identity passes through normalization.
  defp canonical(remote) do
    case String.split(remote, "/", parts: 2) do
      [host, path] -> identity(host, path)
      _invalid -> nil
    end
  end

  defp transport_path(path), do: String.replace_suffix(path, ".git", "")

  defp identity(host, path) when is_binary(host) do
    with true <- valid_host?(host),
         [owner, repository] <- String.split(path, "/"),
         true <- valid_segment?(owner) and valid_segment?(repository),
         canonical = String.downcase(host) <> "/" <> owner <> "/" <> repository,
         true <- byte_size(canonical) <= 200 do
      canonical
    else
      _invalid -> nil
    end
  end

  defp identity(_host, _path), do: nil

  # Explicit transports also support private, single-label Git hosts. read/1
  # separately rejects bare local paths, even when they resemble an identity.
  defp valid_host?(host) do
    labels = String.split(host, ".")

    byte_size(host) <= 253 and
      Enum.all?(labels, &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/i, &1))
  end

  defp valid_segment?(segment),
    do: segment not in [".", ".."] and Regex.match?(~r/\A[a-zA-Z0-9_.-]+\z/, segment)
end
