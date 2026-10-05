defmodule Lemieux.Extensions.Workspace.Containment do
  @moduledoc false

  # Where a file a repository supplies really is, and whether it may be read.
  # Every question about whether something belongs to a repository is asked
  # of real paths: `AGENTS.md -> ../../.ssh/id_rsa` spells a path inside the
  # checkout and reads one outside it. One check answers it for every path a
  # repository supplies — instruction, persona and memory files, imports,
  # skills, commands, subagent definitions and the learned overlay — so a
  # rule cannot hold for one kind of file and not the next: the credential
  # locations first, then the repository's real root. See
  # `Lemieux.Extensions.Workspace.Discovery`'s "What a repository may put in
  # the prompt".

  # Where credentials live, relative to the home directory: the opt-in
  # sandbox's hidden directories (`Lemieux.Environment.Sandbox`) and the
  # credential files that sit beside other tools' settings. Nothing read
  # into a prompt may come from under one of these, whoever asked for it.
  @hidden ~w(.ssh .aws .gnupg .netrc .config/gh .docker .kube .lmx .lemieux
             .config/gcloud .azure .git-credentials .npmrc .pypirc
             .claude/.credentials.json .codex/auth.json)

  # Links followed while resolving one path, as the kernel bounds them
  # (Linux's MAXSYMLINKS), so a loop ends.
  @max_links 40

  @typedoc """
  A repository and a home directory, resolved once: `root` and `home` as
  given, their real paths, and each credential location as `{shown, real}`
  — `{"~/.ssh", "/Users/me/.ssh"}`.
  """
  @type t :: %__MODULE__{
          root: Path.t(),
          real_root: Path.t(),
          home: Path.t(),
          real_home: Path.t(),
          hidden: [{String.t(), Path.t()}]
        }

  @enforce_keys [:root, :real_root, :home, :real_home, :hidden]
  defstruct @enforce_keys

  @typedoc "Why a path was refused: a credential location, as shown, or outside the root."
  @type refusal :: {:hidden, shown :: String.t()} | :outside

  @doc "The scope of a repository at `root` for a person whose home is `home`."
  @spec scope(root :: Path.t(), home :: Path.t()) :: t()
  def scope(root, home) do
    home = Path.expand(home)

    %__MODULE__{
      root: root,
      real_root: real_path(root),
      home: home,
      real_home: real_path(home),
      hidden: Enum.map(@hidden, &{"~/" <> &1, real_path(Path.join(home, &1))})
    }
  end

  @doc """
  Where `path` really is, and whether a repository may supply it: `{:ok,
  real}` when its real path is inside the scope's root and in no credential
  location, else why not. A credential location is refused even inside the
  root, which it is whenever the home directory is itself a repository.
  """
  @spec check(path :: Path.t(), scope :: t()) :: {:ok, Path.t()} | refusal()
  def check(path, %__MODULE__{} = scope) do
    real = real_path(path)

    cond do
      shown = hidden(real, scope) -> {:hidden, shown}
      inside?(real, scope.real_root) -> {:ok, real}
      true -> :outside
    end
  end

  @doc """
  The credential location `real` is in, as shown (`"~/.ssh"`), or `nil`.

  Compared without regard to case: the default file systems of macOS and
  Windows are case-insensitive, so `~/.SSH/id_rsa` opens the key, and a
  refused directory that happens to differ only in case on Linux is a
  refusal too many, not a key read.
  """
  @spec hidden(real :: Path.t(), scope :: t()) :: String.t() | nil
  def hidden(real, %__MODULE__{hidden: hidden}) do
    real = String.downcase(real)

    Enum.find_value(hidden, fn {shown, location} ->
      if inside?(real, String.downcase(location)), do: shown
    end)
  end

  @doc """
  The path the kernel would open: every symlink on the way replaced by its
  target, resolved one component at a time from the path's own root, as
  the kernel walks it.

  A `..` goes up from the directory reached so far, not from the spelling:
  with `d -> /elsewhere/inner`, `d/../x` is `/elsewhere/x`. Collapsing it as
  text first — `Path.expand/1` — answered `<repository>/x`, and a
  repository's `AGENTS.md -> d/../x` was read from outside it while judged to
  be inside. A link's target is spliced in the same way, unexpanded.

  `path` is absolute or relative to the working directory; `~` is not
  expanded. Past #{@max_links} links, or from a component that does not
  exist, the rest of the path is taken as written.
  """
  @spec real_path(path :: Path.t()) :: Path.t()
  def real_path(path) do
    [root | parts] = path |> Path.absname() |> Path.split()
    walk(parts, root, 0)
  end

  @doc "Whether `target` is `root` or below it; both are expected to be real paths."
  @spec inside?(target :: Path.t(), root :: Path.t()) :: boolean()
  def inside?(target, root),
    do: target == root or String.starts_with?(target, String.trim_trailing(root, "/") <> "/")

  @doc """
  Splits `paths` into those a repository may supply under `scope` and a
  diagnostic for each of the rest (`check/2`). `nil` keeps everything: a
  person's own files are theirs, links and all.
  """
  @spec split(paths :: [Path.t()], scope :: t() | nil) :: {[Path.t()], [String.t()]}
  def split(paths, nil), do: {paths, []}

  def split(paths, %__MODULE__{} = scope) do
    {kept, notes} =
      Enum.reduce(paths, {[], []}, fn path, {kept, notes} ->
        case check(path, scope) do
          {:ok, _real} -> {[path | kept], notes}
          refusal -> {kept, [refused(path, refusal) | notes]}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(notes)}
  end

  @doc """
  The diagnostic for a file `shown` that was not read, and why. A path
  inside a real root can only resolve outside it through a symlink, so that
  is what the sentence says.
  """
  @spec refused(shown :: String.t(), refusal :: refusal()) :: String.t()
  def refused(shown, {:hidden, location}),
    do: "#{shown} resolves into #{location}, where credentials live, and was not read"

  def refused(shown, :outside),
    do: "#{shown} is a symlink to a file outside the repository and was not read"

  defp walk([], resolved, _links), do: resolved
  defp walk(["." | rest], resolved, links), do: walk(rest, resolved, links)
  defp walk([".." | rest], resolved, links), do: walk(rest, Path.dirname(resolved), links)

  defp walk([part | rest], resolved, links) do
    candidate = Path.join(resolved, part)

    case File.read_link(candidate) do
      {:ok, target} when links < @max_links -> follow(target, rest, resolved, links + 1)
      _not_a_link_or_too_many -> walk(rest, candidate, links)
    end
  end

  # A relative target continues from the directory the link is in; any other
  # starts again from its own root — a drive's, on Windows.
  defp follow(target, rest, directory, links) do
    case Path.type(target) do
      :relative ->
        walk(Path.split(target) ++ rest, directory, links)

      _absolute_or_volume_relative ->
        [root | parts] = target |> Path.absname(directory) |> Path.split()
        walk(parts ++ rest, root, links)
    end
  end
end
