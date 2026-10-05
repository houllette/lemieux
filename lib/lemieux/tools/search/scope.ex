defmodule Lemieux.Tools.Search.Scope do
  @moduledoc """
  Where a search looks: the model's `path`, confined to the working directory
  and classified as a file or a directory.

  Confinement is checked here, before any helper command runs, because the
  helpers take a path on a command line: `rg -- ../../etc` would search
  wherever it pointed. `Path.safe_relative/2` is the same symlink-aware check
  `Lemieux.Environment.Local` makes for `read`, so a search cannot see a file
  `read` would refuse.

  An absolute path that lies inside the working directory is accepted and
  made relative. Models copy absolute paths out of compiler errors and stack
  traces, and refusing one that names a file in the project answers a
  correct request with an error about something else.
  """

  alias Lemieux.Environment

  @typedoc "A confined search location; `relative` is `\"\"` for the working directory itself."
  @type t :: %{relative: String.t(), kind: :directory | :file}

  @doc """
  Resolves `path` (a string, or `nil` for the working directory).
  """
  @spec resolve(environment :: Environment.t(), cwd :: Path.t(), path :: term()) ::
          {:ok, t()} | {:error, String.t()}
  def resolve(environment, cwd, path) do
    with {:ok, given} <- given(path),
         {:ok, relative} <- confine(cwd, given),
         {:ok, kind} <- kind(environment, cwd, relative, given) do
      {:ok, %{relative: relative, kind: kind}}
    end
  end

  @doc """
  The path to show the model for `file`, a path relative to the scope's
  directory.
  """
  @spec display(scope :: t(), file :: String.t()) :: String.t()
  def display(%{relative: ""}, file), do: file
  def display(%{kind: :file, relative: relative}, _file), do: relative
  def display(%{relative: relative}, file), do: relative <> "/" <> file

  @doc "How the scope reads in a sentence: the path, or \"the working directory\"."
  @spec describe(scope :: t()) :: String.t()
  def describe(%{relative: ""}), do: "the working directory"
  def describe(%{relative: relative}), do: relative

  defp given(nil), do: {:ok, "."}
  defp given(""), do: {:ok, "."}
  defp given(path) when is_binary(path), do: {:ok, path}
  defp given(_path), do: {:error, "path must be a string"}

  defp confine(cwd, given) do
    relative = relativize(cwd, given)

    case Path.safe_relative(relative, cwd) do
      {:ok, confined} -> {:ok, confined}
      :error -> {:error, "#{given}: is outside the working directory"}
    end
  end

  @doc """
  `given` relative to `cwd` when it is an absolute path inside `cwd`; unchanged
  otherwise, for the confinement check to accept or refuse.
  """
  @spec relativize(cwd :: Path.t(), given :: String.t()) :: String.t()
  def relativize(cwd, given) do
    if Path.type(given) == :absolute do
      expanded = Path.expand(given)
      root = Path.expand(cwd)

      cond do
        expanded == root -> "."
        String.starts_with?(expanded, root <> "/") -> Path.relative_to(expanded, root)
        true -> given
      end
    else
      given
    end
  end

  defp kind(environment, cwd, relative, given) do
    case Environment.list_dir(environment, cwd, listable(relative)) do
      {:ok, _entries} -> {:ok, :directory}
      {:error, :enotdir} -> {:ok, :file}
      # An environment that cannot list directories can still run `rg` on the
      # path; treating it as a directory lets the helper decide.
      {:error, :unsupported} -> {:ok, :directory}
      {:error, :enoent} -> {:error, "#{given}: no such file or directory"}
      {:error, :outside_worktree} -> {:error, "#{given}: is outside the working directory"}
      {:error, reason} -> {:error, "#{given}: #{format(reason)}"}
    end
  end

  defp listable(""), do: "."
  defp listable(relative), do: relative

  defp format(reason) when is_atom(reason), do: :file.format_error(reason) |> to_string()
  defp format(reason), do: inspect(reason)
end
