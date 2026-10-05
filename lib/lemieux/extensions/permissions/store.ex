defmodule Lemieux.Extensions.Permissions.Store do
  @moduledoc """
  The rules a person chose to remember, kept in one small JSON file.

      {"version": 1, "allow": ["Bash(mix test:*)", "mcp__github__create_issue"]}

  One file per repository is the host's choice: `lmx` keeps it under
  `~/.lmx`, keyed by the repository, so "always allow `mix test` here" does
  not follow a person into the next checkout — and is not written into the
  checkout, where it would be committed or read by somebody else's agent.

  The file is read on every decision rather than cached. A decision is one
  tool call, the file is a few hundred bytes, and a cache would need an owner
  process and an invalidation story for the second session in the same
  repository. Writes go to a temporary file renamed into place, so a reader
  never sees half a file; two sessions remembering at the same instant can
  lose one of the two rules, which costs one more question later.
  """

  @doc """
  The remembered rule strings; an absent file has none.

  An unreadable or malformed file is an error rather than an empty list, so
  the caller can fall back to asking instead of silently forgetting.
  """
  @spec read(path :: Path.t() | nil) :: {:ok, [String.t()]} | {:error, String.t()}
  def read(nil), do: {:ok, []}

  def read(path) when is_binary(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, %{"version" => 1, "allow" => allow}} when is_list(allow) <- JSON.decode(contents),
         true <- Enum.all?(allow, &is_binary/1) do
      {:ok, allow}
    else
      {:error, :enoent} -> {:ok, []}
      {:error, reason} when is_atom(reason) -> {:error, "#{path}: #{:file.format_error(reason)}"}
      _malformed -> {:error, "#{path} is not a version 1 permission file"}
    end
  end

  @doc """
  Adds `rule` to the file at `path`, creating it (and its directory, private
  to the user) when needed. A rule already present is not added twice.
  """
  @spec add(path :: Path.t(), rule :: String.t()) :: :ok | {:error, String.t()}
  def add(path, rule) when is_binary(path) and is_binary(rule) do
    with {:ok, rules} <- read(path) do
      if rule in rules, do: :ok, else: write(path, rules ++ [rule])
    end
  end

  @doc "Removes `rule` from the file at `path`; absent is not an error."
  @spec remove(path :: Path.t(), rule :: String.t()) :: :ok | {:error, String.t()}
  def remove(path, rule) when is_binary(path) and is_binary(rule) do
    with {:ok, rules} <- read(path) do
      if rule in rules, do: write(path, List.delete(rules, rule)), else: :ok
    end
  end

  defp write(path, rules) do
    directory = Path.dirname(path)
    temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    contents = JSON.encode!(%{"version" => 1, "allow" => rules})

    with :ok <- ensure_directory(directory),
         :ok <- File.write(temporary, contents),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, "could not save #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp ensure_directory(directory) do
    if File.dir?(directory) do
      :ok
    else
      with :ok <- File.mkdir_p(directory), do: File.chmod(directory, 0o700)
    end
  end
end
