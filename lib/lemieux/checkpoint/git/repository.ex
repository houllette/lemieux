defmodule Lemieux.Checkpoint.Git.Repository do
  @moduledoc false

  # How every host-side git run against the agent's repository is made, so
  # that nothing the repository configures runs on this machine. The rules —
  # why a git directory of its own, what is read from the real repository and
  # how, where the private directory lives — are `Lemieux.Checkpoint.Git`'s
  # moduledoc, "Nothing the repository configures runs"; this is how they are
  # done.
  #
  # Two ways to run git, and only two:
  #
  #   * `real/2`, against the repository itself, for the few questions that
  #     need its own configuration and nothing else: where it is
  #     (`rev-parse`), whether a directory is ignored (`check-ignore
  #     --no-index`), what a setting says (`config`). None of them reads the
  #     index, an object or an attribute, which is where a repository's
  #     configuration turns into a program: `core.fsmonitor` runs when the
  #     index is read, a filter driver when content passes between the work
  #     tree and the object store, a partial clone's fetch when an object is
  #     missing. The command-line settings and variables below are a second
  #     line, for a git that reads more than the question needs.
  #   * `run/3`, inside `with_private/3`: a git directory of this module's
  #     making, outside the work tree, whose configuration it wrote, with the
  #     work tree, a copy of the index and the repository's own object store
  #     handed to it. Everything that touches content or objects runs there.

  alias Lemieux.Environment.Sandbox

  @enforce_keys [:root, :prefix, :git_dir, :common_dir, :object_format]
  defstruct [:root, :prefix, :git_dir, :common_dir, :object_format]

  @typedoc """
  A repository as `locate/1` found it: the work tree's root, the working
  directory's place in it, its git directory (a linked worktree's own), the
  directory every worktree shares (objects, `info/`, refs) and how its
  objects are named.
  """
  @type t :: %__MODULE__{
          root: Path.t(),
          prefix: String.t(),
          git_dir: Path.t(),
          common_dir: Path.t(),
          object_format: :sha | :sha256
        }

  @typedoc "A private git directory and how git is run against it."
  @type private :: %{
          dir: Path.t(),
          root: Path.t(),
          env: [{String.t(), String.t() | nil}],
          settings: [String.t()]
        }

  # For a question asked of the real repository: settings that turn off what
  # its configuration could start, should a git version read more than the
  # question needs. `-c` puts them above every configuration file.
  # `protocol.allow=never` is for a fetch nobody asked for, which
  # `GIT_NO_LAZY_FETCH` (git 2.44 and later) also stops.
  @hardening [
    "-c",
    "core.fsmonitor=false",
    "-c",
    "core.hooksPath=/dev/null",
    "-c",
    "core.sshCommand=",
    "-c",
    "diff.external=",
    "-c",
    "protocol.allow=never"
  ]

  # How git runs on Unix: standard error to the file `$1` names, standard
  # output alone to the pipe this VM reads (see `git/4`).
  @separated ~S(errors=$1; shift; exec "$@" 2>"$errors")
  @discarded "/dev/null"

  # Variables that would point git at another repository or name a program
  # for it to run. Cleared for both kinds of run: the snapshot belongs to the
  # working directory's repository, not to a `GIT_DIR` a host process
  # happened to inherit.
  @repository_variables ~w(GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY)
  @cleared @repository_variables ++
             ~w(GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE GIT_ATTR_SOURCE
                GIT_EXTERNAL_DIFF GIT_PAGER GIT_SSH GIT_SSH_COMMAND GIT_ASKPASS GIT_EDITOR
                GIT_SEQUENCE_EDITOR GIT_PROXY_COMMAND)

  # Configuration a host or CI gives every git it runs (`safe.directory`, an
  # identity) is the person's, and stays for the questions asked of the real
  # repository. A private directory takes none: its configuration is the
  # file this module wrote and the settings it copied.
  @private_cleared ~w(GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT)

  # Settings copied from the repository into a private directory, by name.
  # Each decides how a file's bytes or name are read — line endings, letter
  # case, Unicode normalisation, the executable bit, symbolic links, what is
  # ignored — so that a snapshot sees the work tree as the person's own git
  # does, and the copied index's cached entries stay true. None names a
  # program: a filter driver, `core.fsmonitor`, a hook path, a remote's URL
  # (whose fetch a partial clone runs on a missing object) are exactly the
  # settings not copied.
  @work_tree_settings ~w(core.autocrlf core.eol core.ignorecase core.precomposeunicode
                         core.filemode core.symlinks core.excludesfile core.attributesfile
                         core.checkstat core.trustctime core.sharedrepository core.longpaths
                         core.protecthfs core.protectntfs)

  @doc """
  Finds the repository whose work tree holds `cwd`.

  `:skipped` when `cwd` is in no work tree git can read here;
  `{:error, :foreign_work_tree}` when the work tree git reports is not the
  directory holding the repository's `.git` — a `core.worktree` naming
  another directory (see `Lemieux.Checkpoint.Git`).
  """
  @spec locate(cwd :: Path.t()) ::
          {:ok, t()} | :skipped | {:error, :git_not_found | :foreign_work_tree}
  def locate(cwd) when is_binary(cwd) do
    arguments = [
      "rev-parse",
      "--show-toplevel",
      "--show-prefix",
      "--absolute-git-dir",
      "--git-common-dir",
      "--show-object-format"
    ]

    with true <- File.dir?(cwd),
         {:ok, output} <- real(cwd, arguments),
         [root, prefix, git_dir, common, format | _rest] <- lines(output) do
      repository = %__MODULE__{
        root: root,
        prefix: prefix,
        git_dir: git_dir,
        common_dir: Path.expand(common, cwd),
        object_format: object_format(format)
      }

      if own_work_tree?(repository), do: {:ok, repository}, else: {:error, :foreign_work_tree}
    else
      {:error, :git_not_found} = error -> error
      _not_a_work_tree -> :skipped
    end
  end

  # Exactly as git printed them, a line each: a trimmed path is another path.
  defp lines(output) do
    output
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
  end

  # A git older than 2.25 does not know the option and prints it back.
  defp object_format("sha256"), do: :sha256
  defp object_format(_sha1_or_an_older_git), do: :sha

  # The work tree git reports must be where the repository's `.git` is: a
  # directory, or a gitfile (a linked worktree's, a submodule's) naming the
  # git directory git found. A repository whose `core.worktree` names another
  # directory fails this — `core.worktree = /home/someone` in a `.git/config`
  # a sandboxed command wrote would otherwise have the next snapshot add the
  # home directory's small untracked files, credentials among them, to the
  # repository's object store, where that command can read them back.
  defp own_work_tree?(%__MODULE__{root: root, git_dir: git_dir}) do
    dot_git = Path.join(root, ".git")

    target =
      case File.lstat(dot_git) do
        {:ok, %File.Stat{type: :regular}} -> gitfile_target(dot_git, root)
        {:ok, %File.Stat{type: type}} when type in [:directory, :symlink] -> dot_git
        _missing -> nil
      end

    is_binary(target) and Sandbox.real(target) == Sandbox.real(git_dir)
  end

  defp gitfile_target(path, root) do
    case File.read(path) do
      {:ok, "gitdir: " <> rest} -> rest |> String.trim_trailing() |> Path.expand(root)
      _unreadable -> nil
    end
  end

  @doc """
  Whether the repository ignores the working directory: `check-ignore` with
  `--no-index`, which reads ignore files and nothing else.
  """
  @spec ignored?(repository :: t()) :: boolean()
  def ignored?(%__MODULE__{prefix: ""}), do: false

  def ignored?(%__MODULE__{root: root, prefix: prefix}) do
    match?({:ok, _ignored}, real(root, ["check-ignore", "--no-index", "-q", "--", prefix]))
  end

  @doc """
  Asks the real repository a question (see the comment at the top): only
  `rev-parse`, `check-ignore --no-index` and `config` are asked this way.
  """
  @spec real(directory :: Path.t(), arguments :: [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def real(directory, arguments),
    do: git(directory, @hardening ++ arguments, real_env(true), @discarded)

  # The person's own configuration stays, `safe.directory` included; the
  # system-wide file is left out of the answers, except where `settings/2`
  # says why not (and then whatever the host's environment says about it
  # holds).
  defp real_env(nosystem?) do
    [{"GIT_OPTIONAL_LOCKS", "0"}, {"GIT_NO_LAZY_FETCH", "1"}, {"GIT_TERMINAL_PROMPT", "0"}] ++
      if(nosystem?, do: [{"GIT_CONFIG_NOSYSTEM", "1"}], else: []) ++
      Enum.map(@cleared, &{&1, nil})
  end

  @doc """
  The settings `with_private/3` applies, read from the repository as values:
  `:work_tree`, the ones that decide how files read; `:status`, those and the
  current branch's upstream (its `remote` and `merge`, and that remote's
  fetch refspecs), from which `git status --branch` says how far ahead or
  behind the branch is.

  Read with the system-wide file included, unlike `real/2`'s questions: a
  value is only read here, never run, and the system file is where Git for
  Windows sets `core.autocrlf`, which decides what every text file hashes to.
  """
  @spec settings(repository :: t(), which :: :work_tree | :status) :: [{String.t(), String.t()}]
  def settings(%__MODULE__{} = repository, which) do
    arguments = @hardening ++ ["config", "-z", "--get-regexp", "^(core|branch|remote)\\."]

    # A key `-c` cannot pass on as itself is dropped: `-c` splits at the
    # first `=`, and a subsection may hold one. `remote.a=b.fetch`, read
    # back for a branch whose remote is `a=b`, reached the private directory
    # as `remote.a`, set to `b.fetch=…` — a setting nobody made. `git
    # status` reads only refspecs there, so nothing came of it; this keeps
    # what a repository can set in a private directory to the names listed
    # here.
    pairs =
      case git(repository.root, arguments, real_env(false), @discarded) do
        {:ok, output} -> output |> pairs() |> Enum.reject(&String.contains?(elem(&1, 0), "="))
        # Status 1: none of them is set.
        {:error, _none_or_unreadable} -> []
      end

    work_tree = Enum.filter(pairs, fn {key, _value} -> key in @work_tree_settings end)

    case which do
      :work_tree -> work_tree
      :status -> work_tree ++ upstream(pairs, branch(repository))
    end
  end

  # `--get-regexp -z` prints each as `key\nvalue\0`; a key set with no value
  # (`[core] ignorecase`) is true.
  defp pairs(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.map(fn entry ->
      case String.split(entry, "\n", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, "true"}
      end
    end)
  end

  defp upstream(_pairs, nil), do: []

  defp upstream(pairs, branch) do
    own =
      Enum.filter(pairs, fn {key, _value} ->
        key in ~w(branch.#{branch}.remote branch.#{branch}.merge)
      end)

    remote =
      Enum.find_value(own, fn {key, value} -> if key == "branch.#{branch}.remote", do: value end)

    own ++ Enum.filter(pairs, fn {key, _value} -> remote && key == "remote.#{remote}.fetch" end)
  end

  @doc "The branch `HEAD` names, read from the HEAD file itself; `nil` when detached."
  @spec branch(repository :: t()) :: String.t() | nil
  def branch(%__MODULE__{git_dir: git_dir}) do
    case File.read(Path.join(git_dir, "HEAD")) do
      {:ok, "ref: refs/heads/" <> name} -> String.trim(name)
      _detached_or_unreadable -> nil
    end
  end

  @doc """
  Runs `fun` with a private git directory for `repository`, removed again
  when `fun` returns or raises.

  Options:

    * `:scratch` — the directory to make it in (see `Lemieux.Checkpoint.Git`
      for why a checkpoint store's own, and what the system's temporary
      directory leaves open). Defaults to the latter.
    * `:index` — `:copy`, the repository's index with its modification time
      (see `Lemieux.Checkpoint.Git`), or `:none` (default).
    * `:refs` — let git read the repository's refs and `HEAD`, for
      `show-ref` and `status` (default `false`).
    * `:settings` — `[{key, value}]` from `settings/2`, applied with `-c`.

  Nothing here raises: a directory that cannot be made is
  `{:error, {:private_index, reason}}`.
  """
  @spec with_private(repository :: t(), opts :: keyword(), fun :: (private() -> result)) ::
          result | {:error, {:private_index, term()}}
        when result: term()
  def with_private(%__MODULE__{} = repository, opts, fun) when is_function(fun, 1) do
    with {:ok, base} <- scratch(Keyword.get(opts, :scratch)) do
      dir = Path.join(base, "lemieux-git-" <> random_name())

      case File.mkdir(dir) do
        :ok ->
          try do
            with :ok <- File.chmod(dir, 0o700),
                 :ok <- populate(dir, repository, opts) do
              fun.(private(dir, repository, opts))
            else
              {:error, reason} -> {:error, {:private_index, reason}}
            end
          after
            File.rm_rf(dir)
          end

        {:error, reason} ->
          {:error, {:private_index, reason}}
      end
    end
  end

  defp scratch(nil) do
    case System.tmp_dir() do
      nil -> {:error, {:private_index, :no_temporary_directory}}
      directory -> {:ok, directory}
    end
  end

  defp scratch(directory) when is_binary(directory) do
    with :ok <- File.mkdir_p(directory),
         :ok <- File.chmod(directory, 0o700) do
      {:ok, directory}
    else
      {:error, reason} -> {:error, {:private_index, reason}}
    end
  end

  defp random_name, do: 12 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  defp populate(dir, repository, opts) do
    refs? = Keyword.get(opts, :refs, false)

    with :ok <- File.write(Path.join(dir, "config"), config(repository), [:exclusive]),
         :ok <- File.write(Path.join(dir, "global"), "", [:exclusive]),
         :ok <- File.write(Path.join(dir, "HEAD"), head(repository, refs?), [:exclusive]),
         :ok <- refs(dir, repository, refs?),
         :ok <- shallow(dir, repository, refs?),
         :ok <- info(dir, repository) do
      index(dir, repository, Keyword.get(opts, :index, :none))
    end
  end

  # All the configuration a private directory's git reads from a file.
  # `hooksPath` and `fsmonitor` say what they would say anyway, for anybody
  # reading it; the extensions are the repository's, without which its
  # objects or refs could not be read at all.
  defp config(repository) do
    extensions =
      Enum.reject(
        [
          if(repository.object_format == :sha256, do: "\tobjectFormat = sha256\n"),
          if(File.dir?(Path.join(repository.common_dir, "reftable")),
            do: "\trefStorage = reftable\n"
          )
        ],
        &is_nil/1
      )

    """
    [core]
    \trepositoryformatversion = #{if extensions == [], do: 0, else: 1}
    \tbare = false
    \tfsmonitor = false
    \thooksPath = /dev/null
    \tuntrackedCache = false
    \tsplitIndex = false
    \tsafecrlf = false
    """ <> if(extensions == [], do: "", else: "[extensions]\n" <> Enum.join(extensions))
  end

  # `HEAD` must name something for git to take the directory for a
  # repository. With refs, it is the repository's own `HEAD`, as text, so
  # `status` and `show-ref --head` resolve it through the refs linked below.
  defp head(repository, true) do
    head =
      case File.read(Path.join(repository.git_dir, "HEAD")) do
        {:ok, "ref: refs/" <> _rest = text} -> first_line(text)
        {:ok, text} -> if object_name?(first_line(text)), do: first_line(text)
        _unreadable -> nil
      end

    (head || "ref: refs/heads/lemieux") <> "\n"
  end

  defp head(_repository, false), do: "ref: refs/heads/lemieux\n"

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd() |> String.trim()

  defp object_name?(text), do: Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, text)

  # Refs are read through links to the repository's own, never copied: a
  # repository can hold tens of thousands of tags, and reading a ref runs
  # nothing. Without refs, an empty directory, all git asks for. A file
  # system that will not make a link (Windows without the privilege) gets the
  # empty one too, and a report then says less about `HEAD`.
  defp refs(dir, repository, true) do
    Enum.each(["refs", "packed-refs", "reftable"], fn name ->
      source = Path.join(repository.common_dir, name)
      if File.exists?(source), do: File.ln_s(source, Path.join(dir, name))
    end)

    if File.exists?(Path.join(dir, "refs")), do: :ok, else: File.mkdir(Path.join(dir, "refs"))
  end

  defp refs(dir, _repository, false), do: File.mkdir(Path.join(dir, "refs"))

  # A shallow clone's list of the commits its history stops at, copied in
  # with the refs, as data. Without it `status --branch`, counting how far a
  # local commit is ahead of its upstream, looked for the parents of the
  # oldest commit there, which were never fetched, and failed (`fatal: bad
  # revision`): the startup status of a `git clone --depth 1` with one
  # commit of the person's own on it read "not a repository".
  defp shallow(dir, repository, true),
    do: copy_regular(Path.join(repository.common_dir, "shallow"), dir, "shallow")

  defp shallow(_dir, _repository, false), do: :ok

  # The repository's own ignore and attribute files, as files of this
  # directory. They are read as data — patterns — and an attribute can only
  # choose among the filter drivers configured somewhere, of which a private
  # directory has none; the line-ending and encoding attributes are git's own
  # conversions, which run nothing. Only a file that is one: a link there is
  # somebody pointing the copy at a file elsewhere on this machine.
  defp info(dir, repository) do
    with :ok <- File.mkdir(Path.join(dir, "info")),
         :ok <- copy_info(dir, repository, "exclude") do
      copy_info(dir, repository, "attributes")
    end
  end

  defp copy_info(dir, repository, name),
    do: copy_regular(Path.join([repository.common_dir, "info", name]), dir, "info/" <> name)

  defp copy_regular(source, dir, name) do
    case File.lstat(source) do
      {:ok, %File.Stat{type: :regular}} -> copy_new(source, dir, name)
      _absent_or_not_a_file -> :ok
    end
  end

  defp index(_dir, _repository, :none), do: :ok

  # A repository with no index yet (nothing ever added) starts from an empty
  # one, as git itself would. A split index also needs its shared part, read
  # through a link as refs are.
  defp index(dir, repository, :copy) do
    real = Path.join(repository.git_dir, "index")

    case File.stat(real, time: :posix) do
      {:ok, %File.Stat{type: :regular, mtime: mtime}} ->
        with :ok <- copy_new(real, dir, "index"),
             :ok <- File.touch(Path.join(dir, "index"), mtime),
             do: shared_index(dir, repository)

      _no_index ->
        :ok
    end
  end

  defp shared_index(dir, repository) do
    for shared <- Path.wildcard(Path.join(repository.git_dir, "sharedindex.*")),
        do: File.ln_s(shared, Path.join(dir, Path.basename(shared)))

    :ok
  end

  # Into a file that must not exist yet: `:exclusive` refuses a name that is
  # already there, a symbolic link included, rather than following it. A
  # source that is not there is nothing to copy.
  defp copy_new(source, dir, name) do
    if File.regular?(source) do
      with {:ok, device} <- File.open(Path.join(dir, name), [:write, :exclusive, :binary]) do
        try do
          case File.copy(source, device) do
            {:ok, _bytes} -> :ok
            {:error, reason} -> {:error, reason}
          end
        after
          File.close(device)
        end
      end
    else
      :ok
    end
  end

  defp private(dir, repository, opts) do
    settings =
      opts
      |> Keyword.get(:settings, [])
      |> Enum.flat_map(fn {key, value} -> ["-c", key <> "=" <> value] end)

    env =
      [
        {"GIT_DIR", dir},
        {"GIT_WORK_TREE", repository.root},
        {"GIT_INDEX_FILE", Path.join(dir, "index")},
        {"GIT_OBJECT_DIRECTORY", Path.join(repository.common_dir, "objects")},
        {"GIT_CONFIG_NOSYSTEM", "1"},
        {"GIT_CONFIG_GLOBAL", Path.join(dir, "global")},
        {"GIT_OPTIONAL_LOCKS", "0"},
        {"GIT_NO_LAZY_FETCH", "1"},
        {"GIT_TERMINAL_PROMPT", "0"}
      ] ++ Enum.map((@cleared -- @repository_variables) ++ @private_cleared, &{&1, nil})

    %{dir: dir, root: repository.root, env: env, settings: settings}
  end

  @doc """
  Runs git in a private directory. A path given here is a file's name, never
  a pattern (`GIT_LITERAL_PATHSPECS`) — without that, restoring `a[1].txt`
  would also overwrite `a1.txt` — unless `literal: false` lets pathspec magic
  such as `:(attr:!filter)` through. `:env` adds variables.
  """
  @spec run(private :: private(), arguments :: [String.t()], opts :: keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def run(private, arguments, opts \\ []) do
    literal = if Keyword.get(opts, :literal, true), do: "1"
    env = [{"GIT_LITERAL_PATHSPECS", literal} | private.env] ++ Keyword.get(opts, :env, [])
    git(private.root, private.settings ++ arguments, env, Path.join(private.dir, "stderr"))
  end

  # What git writes to standard error never joins the answer that is read.
  # A sandboxed command decides some of what git warns about — an index
  # extension git does not know (`ignoring ZZZZ extension`), a ref named
  # `HEAD`, an attribute file it cannot parse — and git writes a warning
  # before its answer: joined, it became part of the answer's first entry.
  # The first submodule in `ls-files --stage` then read as none, and `add
  # --update` ran git in it under the configuration the command had written
  # there (found in review, 2026-10). Nor does it go to this VM's own
  # standard error, which in the terminal UI is the screen.
  #
  # So on Unix git runs under a shell (`@separated`), which hands its
  # standard error to `errors`: a file of the private directory's, read back
  # for the reason when git fails, or `/dev/null` for a question asked of
  # the real repository, whose failures say only "no". Windows has no such
  # shell, and no sandbox for a command to escape
  # (`Lemieux.Environment.Sandbox`), so there standard error still joins the
  # answer; what parses one that decides anything checks its form
  # (`Lemieux.Checkpoint.Git`).
  defp git(directory, arguments, env, errors) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        case spawn_git(git, ["--no-pager", "-C", directory | arguments], env, errors) do
          {output, 0} -> {:ok, output}
          {output, status} -> {:error, {:git, status, String.trim(output <> errors(errors))}}
        end
    end
  end

  defp spawn_git(git, arguments, env, errors) do
    case shell() do
      nil -> System.cmd(git, arguments, env: env, stderr_to_stdout: true)
      shell -> System.cmd(shell, ["-c", @separated, "lmx-git", errors, git | arguments], env: env)
    end
  end

  # dash where there is one — macOS ships it beside a `/bin/sh` that is
  # bash, which takes about 2 ms more to start, and a snapshot runs git a
  # dozen times — and `/bin/sh` otherwise.
  defp shell do
    if match?({:unix, _name}, :os.type()),
      do: Enum.find(["/bin/dash", "/bin/sh"], &File.regular?/1)
  end

  defp errors(@discarded), do: ""

  defp errors(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, _not_written} -> ""
    end
  end
end
