defmodule Lemieux.Checkpoint.Git do
  @moduledoc """
  Git trees of a working directory, taken without touching the repository's
  index, branches, stash or refs, and without running anything the
  repository configures.

  `Lemieux.Checkpoint` saves a file's contents before `write`, `edit` or
  `apply_patch` changes it, but a `bash` command can change any file, and
  nothing announces which. For those the checkpoint records the working tree
  as a git tree object immediately before each command and immediately after
  it, and undoing the turn restores the paths that differ between the two.

  ## Nothing the repository configures runs

  Snapshots and restores run git on this machine, outside any sandbox the
  session's commands run in, in a repository those commands can write — and
  `.git/config` is part of it. A repository's configuration names programs
  git starts by itself: `core.fsmonitor` when it reads the index, a filter
  driver's `clean`, `smudge` or `process` when content passes between the
  work tree and the object store (chosen by `.gitattributes` or
  `.git/info/attributes`), hooks, and, in a partial clone, the transport a
  missing object is fetched with. A sandboxed command that wrote any of them
  had the next snapshot run it here, unconfined: an escape from `--sandbox`
  through `/undo`'s own bookkeeping (found in review, 2026-10).

  So every git that reads content or objects runs in a git directory of its
  own (`GIT_DIR`), outside the work tree, whose configuration this module
  wrote: the work tree is handed to it (`GIT_WORK_TREE`), the repository's
  object store (`GIT_OBJECT_DIRECTORY`), for a snapshot a copy of its index,
  and for a report its refs. The repository's `.git/config`, `hooks/` and
  `info/` are never read for anything that runs, and neither are the
  system-wide and personal configuration files. What is read from the
  repository is read as data:

    * where it is, whether it ignores the working directory, and what a
      setting says — `git rev-parse`, `git check-ignore --no-index` and `git
      config`, which read no index, no object and no attribute, run against
      it with `core.fsmonitor`, `core.hooksPath`, `core.sshCommand`,
      `diff.external` and every transport turned off on the command line,
      `GIT_CONFIG_NOSYSTEM`, `GIT_OPTIONAL_LOCKS=0` and `GIT_NO_LAZY_FETCH`;
    * settings that decide how a file's bytes and name read and nothing more
      — line endings (`core.autocrlf`, `core.eol`), letter case, Unicode
      normalisation, the executable bit, symbolic links, the person's ignore
      and attribute files — copied by name and applied with `-c`, so a
      snapshot sees the work tree as the person's own git does (and, for
      `status/2`, the branch's upstream: its remote's name, the branch it
      merges and that remote's fetch refspecs, never its URL);
    * `.gitignore` and `.gitattributes` in the work tree and the
      repository's `info/exclude` and `info/attributes`, copied in. Ignore
      rules decide what a snapshot holds, as before. An attribute can only
      choose among filter drivers configured somewhere, and the private
      directory configures none; line-ending and encoding attributes are
      git's own conversions, which run nothing.

  The obvious alternative, the repository's own directory with the dangerous
  settings overridden on the command line, cannot work: a filter driver is
  named by whoever writes the configuration, and `-c` can only override a
  name it knows.

  A submodule is a repository with a configuration of its own, as writable,
  and `git add --update` asks each populated one whether its work tree is
  dirty by running git inside it, under that configuration. So a snapshot
  leaves submodule entries as the index has them — an entry records only the
  commit the submodule is at, which undo never moves — and `status/2`
  compares submodules by that commit alone.

  What git writes to standard error is kept apart from what is read of its
  answer, since a sandboxed command chooses some of the warnings: one git
  wrote ahead of the index listing (about an index extension the command
  added) hid the first submodule from the snapshot, which then ran git in
  it. Where the two cannot be kept apart (Windows), the submodule listing
  is read strictly and an entry it cannot read fails the snapshot.

  The work tree git reports must also be the directory holding the
  repository's `.git` (or the gitfile a linked worktree or submodule has
  there). A `core.worktree` naming another directory is refused
  (`{:error, :foreign_work_tree}`): `core.worktree = /home/someone` written
  by a sandboxed command would have had the next snapshot add the home
  directory's small untracked files — credentials among them — to an object
  store that command can read.

  ### Filtered files

  A file a filter attribute names a driver for (Git LFS, git-crypt,
  `nbstripout`) is one whose index entry holds the filter's output — a
  pointer, ciphertext — not the file. Without the filter, re-hashing it
  would store the whole of an LFS object in `.git/objects`, and restoring
  the index's version would write the pointer over the file. So a snapshot
  leaves tracked filtered files as the index has them and lists them by
  size, modification time and inode (`:filtered`), undo names one a command
  changed instead of putting it back, and `restore/4` refuses one. A file
  tool's change to it is saved and undone like any other
  (`Lemieux.Checkpoint.capture/4`). `-filter`, and `filter` with no driver's
  name, name none for any git: such a file is snapshotted and restored like
  any other.

  ### Where the private directory lives

  It must be out of the session's reach too: a command a sandbox let write
  it — one still running in the background — could put a configuration
  there between its making and git reading it. `Lemieux.Checkpoint` makes it
  in the checkpoint store, under the session's directory (`git/`), which
  `lmx` keeps in `~/.lmx` and `--sandbox` hides. Called directly, without
  `:scratch`, this module makes it in the system's temporary directory,
  which a sandbox lets commands write: still nothing the repository
  configures runs, but a command left running could race to add a setting
  of its own. Either way the directory is made fresh for each call with a
  random name and mode `0700`, and removed afterwards; a name counted up
  from a small number, made with `mkdir -p`, let another user of a shared
  `/tmp` plant the directory first and read the copied index (every file
  name in the repository).

  ## Not touching anything

  `git add` and `git write-tree` against the private index produce the tree
  while the user's index, staged changes included, is never written; no
  commit, branch, ref or stash entry is created, and `GIT_OPTIONAL_LOCKS=0`
  keeps git from taking a lock the user's own `git` may be waiting on. The
  obvious alternative, `git stash create`, writes objects the same way but
  reads the real index and refreshes it, which is a write to a file the
  user's own `git` may be holding at that moment.

  A snapshot starts from a copy of the real index, because its cached stat
  data is what keeps `git add --update` from re-reading every tracked file.
  The copy keeps the original's modification time: git trusts an entry's
  cached stat only when the entry is older than the index file holding it,
  and a copy stamped "now" would make every entry look older, so a file
  rewritten in place within the same second, at the same size, would be
  taken as unchanged. A restore starts from an **empty** private index
  instead, and checks afterwards that each file now hashes to what the tree
  holds. Seeded with a copy, `git restore` once reported success and wrote
  nothing, for exactly that reason; a report that says "restored" about a
  file that was not is worse than one that says it could not.

  ## What a snapshot covers, and what it only notices

  Added to the tree: the tracked files as they are in the working tree, and
  untracked files that `.gitignore` does not exclude — symbolic links as
  links, regular files of at most `:max_untracked_bytes` (1 MB), at most
  `:max_untracked_files` (2,000) of them, counted across the whole
  repository: those in directories git tracks first, then those in
  directories it does not, each in path order. A dataset or a build
  artefact that happens not to be ignored would otherwise be copied into
  `.git/objects` on every command, and would push a new source file beside
  the code out of the count.

  What is left out is still noticed. Each snapshot lists, by size,
  modification time and inode, the untracked files it did not add (too
  large, or past the limit), the files `.gitignore` excludes one by one
  (`.env`) and the tracked filtered files, and names each wholly ignored
  directory (`_build/`, not what is inside it) — up to 2,000 entries. Undo
  cannot put such a file back, since its contents were never saved, but it
  can say that a command changed it, or created or deleted the directory —
  which a person whose `.env` a command rewrote needs to hear more than
  anything undo did put back.

  It also names the directories git does not track at all — `newdir/`, an
  empty `uploads/` — because a tree records no directory without a tracked
  or added file in it, and undo, removing the directories a command's files
  were created in, would otherwise take away an empty directory the person
  already had.

  The snapshot also records `HEAD` (the commit and the branch) and a digest
  of the repository's refs, so undo can say when a command committed,
  switched branches, reset, stashed or pushed. It does not move them back:
  undo puts file contents back and never writes a ref.

  The objects written are unreferenced, so `git gc` eventually removes them;
  an undo after that reports the snapshot as gone rather than guessing. Until
  then they hold the contents of the files they recorded, in the
  repository's own `.git/objects`.

  Snapshots run on this machine, not through the session's environment: they
  need a real repository on a real disk. A working directory that is not a
  git work tree here gets no snapshot (`:skipped`), nor does one inside a
  work tree that the repository ignores (`{:error, :ignored_working_directory}`:
  nothing in it would ever reach a tree), and `Lemieux.Checkpoint` records
  that the command ran unrecorded, so undo can say so.

  The functions that run git in a private directory take `:scratch` among
  their options: where it is made (see above).
  """

  alias Lemieux.Checkpoint.Git.Repository

  @max_untracked_bytes 1_000_000
  @max_untracked_files 2_000
  @max_unsaved 2_000
  @add_batch 100

  @typedoc """
  A file a snapshot noticed but did not save: `why` is `:large` (an untracked
  file over the size limit), `:beyond_limit` (an untracked file past the
  count limit), `:ignored` or `:filtered` (a tracked file a filter
  attribute names, see "Filtered files").
  """
  @type unsaved :: %{
          path: String.t(),
          size: non_neg_integer(),
          mtime: integer(),
          inode: non_neg_integer(),
          why: :large | :beyond_limit | :ignored | :filtered
        }

  @typedoc "Where `HEAD` pointed: the commit, `nil` before the first one, and the branch, `nil` when detached."
  @type head :: %{commit: String.t() | nil, branch: String.t() | nil}

  @typedoc """
  A snapshot: the repository root, the working directory's place in it, the
  tree, `HEAD` and a digest of the refs, what the tree left out (`unsaved`,
  with `unsaved_more` counting any past the 2,000 listed), and the
  directories git does not track at all (`dirs`, each ending in `/`, with
  `dirs_more` counting any past the 2,000 listed).
  """
  @type snapshot :: %{
          root: Path.t(),
          prefix: String.t(),
          tree: String.t(),
          head: head(),
          refs: String.t(),
          unsaved: [unsaved()],
          unsaved_more: non_neg_integer(),
          dirs: [String.t()],
          dirs_more: non_neg_integer()
        }

  @typedoc "Why a working directory gets no snapshot, besides not being in a work tree."
  @type refusal :: :git_not_found | :ignored_working_directory | :foreign_work_tree

  @doc """
  Whether a snapshot of `cwd` can be taken, and of which repository: the
  checks `snapshot/2` makes before it writes anything, for a host that wants
  to say what `/undo` will cover without writing objects to find out
  (`Lemieux.Conversation.Doctor.undo_coverage/2`).

  `{:ok, %{root: root, prefix: prefix}}`, `:skipped` outside a work tree
  git can read here, or `{:error, refusal}`. Runs `git` once, twice in a
  subdirectory of a repository, and neither run reads anything the
  repository configures as a program.
  """
  @spec locate(cwd :: Path.t()) ::
          {:ok, %{root: Path.t(), prefix: String.t()}} | :skipped | {:error, refusal()}
  def locate(cwd) when is_binary(cwd) do
    with {:ok, repository} <- Repository.locate(cwd),
         :ok <- not_ignored(repository) do
      {:ok, %{root: repository.root, prefix: repository.prefix}}
    end
  end

  @doc """
  The commit `HEAD` names in the repository around `cwd`: `{:ok,
  object_name}`, or `:none` outside a work tree git can read here, before
  the first commit, or without git. For a host that says which revision
  work was done against (`Lemieux.A2A.Server`,
  `Lemieux.Extensions.Delegation`).

  Asked as `locate/1` asks the repository (see "Nothing the repository
  configures runs"): `git rev-parse`, which reads the configuration and the
  refs and starts nothing either names, with what a configuration could
  start turned off on the command line as well, and a `GIT_DIR` this VM
  inherited ignored. A plain `git rev-parse` starts nothing today either;
  this keeps every git a host runs in a repository the session's commands
  write on the one path whose rules are written down here.

  Only the object name is taken from what git prints. A command that wrote
  `.git/refs/heads/HEAD` makes git warn `refname 'HEAD' is ambiguous`, with
  the ref's name, before the answer, and a revision read as the whole
  output went to an A2A peer as `warning: ignoring broken ref …`.
  """
  @spec revision(cwd :: Path.t()) :: {:ok, String.t()} | :none
  def revision(cwd) when is_binary(cwd) do
    with {:ok, output} <- Repository.real(cwd, ["rev-parse", "--verify", "HEAD"]),
         [object] <- output |> String.split(["\r\n", "\n"], trim: true) |> Enum.filter(&oid?/1) do
      {:ok, object}
    else
      _no_commit_or_repository -> :none
    end
  end

  defp oid?(line), do: Regex.match?(~r/\A[0-9a-f]{40}([0-9a-f]{24})?\z/, line)

  @doc """
  Records the working tree around `cwd` as a tree object.

  `:skipped` when `cwd` is not inside a git work tree on this machine, and
  `{:error, refusal}` when it gets no snapshot for one of `locate/1`'s
  reasons. Options: `:scratch`, `:max_untracked_bytes`, `:max_untracked_files`.
  """
  @spec snapshot(cwd :: Path.t(), opts :: keyword()) ::
          {:ok, snapshot()} | :skipped | {:error, term()}
  def snapshot(cwd, opts \\ []) do
    with {:ok, repository} <- Repository.locate(cwd),
         :ok <- not_ignored(repository) do
      private = [
        scratch: Keyword.get(opts, :scratch),
        index: :copy,
        refs: true,
        settings: Repository.settings(repository, :work_tree)
      ]

      Repository.with_private(repository, private, &write_tree(repository, &1, opts))
    end
  end

  # A working directory the repository ignores (a scratch directory inside a
  # project) is inside a work tree, but nothing in it is ever added to a
  # tree: every snapshot would be identical and every command's change
  # invisible. Saying so is the only honest answer.
  defp not_ignored(repository) do
    if Repository.ignored?(repository), do: {:error, :ignored_working_directory}, else: :ok
  end

  defp write_tree(repository, private, opts) do
    root = repository.root

    with {:ok, gitlinks} <- gitlinks(private),
         {filtered, driverless} = filtered(private, gitlinks),
         :ok <- update_tracked(private, filtered, gitlinks),
         :ok <- in_batches(private, ["add", "--update"], driverless),
         {:ok, unsaved, dirs} <- add_untracked(root, private, opts),
         {:ok, ignored} <- ignored(root, private),
         {:ok, tree} <- Repository.run(private, ["write-tree"]) do
      {head, refs} = refs(repository, private)
      noticed = Enum.flat_map(filtered, &filtered_entry(root, &1))
      {listed, more} = Enum.split(unsaved ++ ignored ++ noticed, @max_unsaved)
      {dirs, dirs_more} = Enum.split(dirs, @max_unsaved)

      {:ok,
       %{
         root: root,
         prefix: repository.prefix,
         tree: String.trim(tree),
         head: head,
         refs: refs,
         unsaved: listed,
         unsaved_more: length(more),
         dirs: dirs,
         dirs_more: length(dirs_more)
       }}
    end
  end

  # The tracked files `add --update` re-reads: every one, in the usual
  # repository — the cheapest command — but never a submodule, and never a
  # file a filter attribute names a driver for (see "Filtered files"), which
  # `:(attr:!filter)`, git's own pathspec, leaves out — together with the
  # driverless ones `filtered/2` lists, which `write_tree/3` adds by name.
  #
  # A submodule, because `add --update` asks a populated one whether its work
  # tree is dirty by running git inside it, and that git reads the
  # submodule's own configuration — its `core.fsmonitor`, its filters — which
  # a sandboxed command can write as easily as the repository's (and can
  # create, with `git add` of a nested repository). A submodule's entry
  # records only the commit it is at, which undo never moves, so leaving it
  # as the index has it loses nothing.
  #
  # A pathspec matching nothing fails `add` — a repository that tracks only
  # filtered files or submodules — which is nothing to update. A git older
  # than attribute pathspecs (2.13) refuses that magic, and updates every
  # tracked file but the submodules.
  defp update_tracked(private, [], []), do: ok(Repository.run(private, ["add", "--update"]))

  defp update_tracked(private, filtered, gitlinks) do
    excluded = Enum.map(gitlinks, &(":(exclude,literal)" <> &1))
    pathspec = if filtered == [], do: ["." | excluded], else: [":(attr:!filter)" | excluded]

    case Repository.run(private, ["add", "--update", "--" | pathspec], literal: false) do
      {:ok, _output} ->
        :ok

      {:error, _reason} = error ->
        case Repository.run(private, ["ls-files", "-z", "--" | pathspec], literal: false) do
          {:ok, ""} ->
            :ok

          {:ok, _to_update} ->
            error

          {:error, _no_attribute_pathspecs} ->
            ok(Repository.run(private, ["add", "--update", "--", "." | excluded], literal: false))
        end
    end
  end

  # The submodules the index records (mode 160000), by path — or no
  # snapshot. A submodule this misses is one `add --update` runs git in, so
  # an index that cannot be listed, or a listing with an entry that is not
  # `mode object stage<TAB>path`, fails the snapshot rather than being read
  # as fewer submodules: a warning git wrote ahead of the listing, joined to
  # it where standard error cannot be kept apart (see
  # `Lemieux.Checkpoint.Git.Repository`), made the first entry unreadable,
  # and the submodule in it went unnoticed.
  @stage_entry ~r/\A([0-7]{6}) (?:[0-9a-f]{40}|[0-9a-f]{64}) [0-3]\t(.+)\z/s

  defp gitlinks(private) do
    with {:ok, output} <- Repository.run(private, ["ls-files", "-z", "--stage"]) do
      output |> paths() |> Enum.reduce_while({:ok, []}, &gitlink/2)
    end
  end

  defp gitlink(entry, {:ok, gitlinks}) do
    case Regex.run(@stage_entry, entry, capture: :all_but_first) do
      ["160000", path] -> {:cont, {:ok, [path | gitlinks]}}
      [_mode, _path] -> {:cont, {:ok, gitlinks}}
      nil -> {:halt, {:error, {:unreadable_index_entry, String.slice(entry, 0, 200)}}}
    end
  end

  defp ok({:ok, _output}), do: :ok
  defp ok(error), do: error

  # The tracked files a filter attribute names a driver for: listed, not
  # added, since what the index holds for them is the filter's output. A
  # git without attribute pathspecs lists none, and `restore/4` still
  # refuses them.
  #
  # And, apart, the tracked files that have the attribute and name no
  # driver: `-filter` (unset) and a bare `filter` (set), which no git runs
  # a filter for, so their index entries hold the files themselves and they
  # are snapshotted and restored like any other — added by name, since
  # `:(attr:!filter)` leaves them out with the rest. Asked for only where a
  # file names a driver too; otherwise `update_tracked/3` takes every file.
  #
  # `filter=set`, `filter=unset` and `filter=unspecified` name drivers to
  # git but read as no driver in `check-attr`'s answer, which `restore/4`
  # goes by, so they count as driverless here too: what a restore will
  # write must be what the snapshot stored, never the index's copy of a
  # file a command has since changed. For the same reason a driverless file
  # is added or the snapshot fails, and should the listing itself fail,
  # every file with the attribute is left as the index has it and refused
  # on restore. A file outside a sparse checkout (`S` in `ls-files -t`)
  # is not there to add, and naming it fails `add`.
  defp filtered(private, gitlinks) do
    attributed = ["ls-files", "-z", "--", ".", ":(exclude,attr:!filter)"]

    driverless =
      ~w(ls-files -z -t --) ++
        Enum.map(~w(-filter filter filter=set filter=unset filter=unspecified), &":(attr:#{&1})")

    with {:ok, output} <- Repository.run(private, attributed, literal: false),
         [_some | _more] = attributed <- output |> paths() |> Enum.reject(&(&1 in gitlinks)) do
      case Repository.run(private, driverless, literal: false) do
        {:ok, output} -> split_driverless(attributed, output, gitlinks)
        {:error, _reason} -> {attributed, []}
      end
    else
      _none_or_no_attribute_pathspecs -> {[], []}
    end
  end

  defp split_driverless(attributed, tagged, gitlinks) do
    entries =
      for <<tag::binary-size(1), " ", path::binary>> <- paths(tagged),
          path not in gitlinks,
          do: {tag, path}

    named = MapSet.new(entries, &elem(&1, 1))
    {_outside, driverless} = Enum.split_with(entries, &match?({"S", _path}, &1))

    case Enum.reject(attributed, &MapSet.member?(named, &1)) do
      [] -> {[], []}
      filtered -> {filtered, Enum.map(driverless, &elem(&1, 1))}
    end
  end

  defp paths(output), do: String.split(output, <<0>>, trim: true)

  defp filtered_entry(root, path) do
    case File.lstat(Path.join(root, path), time: :posix) do
      {:ok, %File.Stat{type: type} = stat} when type in [:regular, :symlink] ->
        [unsaved(path, stat, :filtered)]

      _gone_or_other ->
        []
    end
  end

  @doc """
  The paths that differ between two trees, relative to the repository root,
  as `{:added | :modified | :deleted, path}`.
  """
  @spec changed(root :: Path.t(), before :: String.t(), later :: String.t(), opts :: keyword()) ::
          {:ok, [{:added | :modified | :deleted, String.t()}]} | {:error, term()}
  def changed(root, before, later, opts \\ []) do
    arguments =
      ~w(diff-tree -r -z --no-renames --no-ext-diff --no-textconv --name-status) ++
        [before, later]

    with {:ok, output} <- objects(root, opts, &Repository.run(&1, arguments)) do
      {:ok, output |> String.split(<<0>>, trim: true) |> Enum.chunk_every(2) |> changes()}
    end
  end

  @typedoc "A path as git stores it: its mode (`100644`, `100755`, `120000`) and blob."
  @type entry :: %{mode: String.t(), blob: String.t()}

  @doc """
  The blob each path has in `tree`, and `nil` for a path the tree does not
  contain.
  """
  @spec blobs(root :: Path.t(), tree :: String.t(), paths :: [String.t()], opts :: keyword()) ::
          {:ok, %{String.t() => String.t() | nil}} | {:error, term()}
  def blobs(root, tree, paths, opts \\ []) do
    with {:ok, entries} <- entries(root, tree, paths, opts), do: {:ok, blob_map(entries)}
  end

  defp blob_map(entries),
    do: Map.new(entries, fn {path, entry} -> {path, entry && entry.blob} end)

  @doc """
  The mode and blob each path has in `tree`, and `nil` for a path the tree
  does not contain. The mode matters as much as the blob: `chmod +x`
  changes nothing else, and undo has to see it to put it back.
  """
  @spec entries(root :: Path.t(), tree :: String.t(), paths :: [String.t()], opts :: keyword()) ::
          {:ok, %{String.t() => entry() | nil}} | {:error, term()}
  def entries(root, tree, paths, opts \\ [])
  def entries(_root, _tree, [], _opts), do: {:ok, %{}}

  def entries(root, tree, paths, opts),
    do: objects(root, opts, &entries_in(&1, tree, paths))

  defp entries_in(private, tree, paths) do
    paths
    |> Enum.chunk_every(@add_batch)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, found} ->
      case Repository.run(private, ["ls-tree", "-r", "-z", tree, "--" | batch]) do
        {:ok, output} -> {:cont, {:ok, Map.merge(found, listed(output))}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, found} -> {:ok, Map.new(paths, &{&1, Map.get(found, &1)})}
      error -> error
    end
  end

  defp listed(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Map.new(fn line ->
      [meta, path] = String.split(line, "\t", parts: 2)
      [mode, _type, blob] = String.split(meta, " ")
      {path, %{mode: mode, blob: blob}}
    end)
  end

  @doc """
  Whether the repository records the executable bit (`core.fileMode`, true
  unless set otherwise). Where it does not, a regular file's mode in a tree
  says nothing about the file on disk, and comparing them would call every
  file nobody touched changed.
  """
  @spec file_mode?(root :: Path.t(), opts :: keyword()) :: boolean()
  def file_mode?(root, _opts \\ []) do
    case Repository.real(root, ["config", "--bool", "core.fileMode"]) do
      {:ok, "false" <> _rest} -> false
      _true_or_unset -> true
    end
  end

  @doc """
  The blob the working-tree file at each path would be stored as, and `nil`
  for a path with no file.

  `git hash-object` rather than hashing the bytes here, so the same
  line-ending conversions apply as when the snapshot was taken; otherwise a
  file nobody touched would read as changed. No filter runs (see the
  moduledoc): a filtered file hashes as its bytes. A symbolic link is hashed
  as git stores one — its target — because `hash-object` would follow it and
  hash whatever it points at, and a link nobody touched would read as
  changed.
  """
  @spec worktree_blobs(root :: Path.t(), paths :: [String.t()], opts :: keyword()) ::
          {:ok, %{String.t() => String.t() | nil}} | {:error, term()}
  def worktree_blobs(root, paths, opts \\ []) do
    with {:ok, entries} <- worktree_entries(root, paths, opts), do: {:ok, blob_map(entries)}
  end

  @doc """
  `worktree_blobs/3` with the mode each file would be stored with: `120000`
  for a symbolic link, `100755` for a regular file whose owner may execute
  it, `100644` otherwise.
  """
  @spec worktree_entries(root :: Path.t(), paths :: [String.t()], opts :: keyword()) ::
          {:ok, %{String.t() => entry() | nil}} | {:error, term()}
  def worktree_entries(root, paths, opts \\ []) do
    work_tree(root, opts, &worktree_entries_in(&1, &2, paths))
  end

  @doc """
  Whether `path`, relative to `root`, lies beyond a symbolic link: whether a
  directory above it, below `root`, is a link. `path` itself may be one; a
  link is an entry like any other, and unlinking it touches nothing it
  points at.

  Git's own rule — `git add` refuses such a path and `git status` reports it
  gone — so no snapshot records one. A path that is beyond a link now had a
  directory above it replaced after the snapshot, and reading or deleting
  it would act on whatever the link reaches, outside the work tree as
  easily as in it: `/undo --force` deleted a file in the directory a link
  pointed at, outside the repository, and reported it as the turn's file
  deleted (found in review, 2026-10). `worktree_entries/3` reads such a
  path as absent, as git does, and undo leaves it alone. `root`'s own
  links are the person's and are followed.
  """
  @spec beyond_link?(root :: Path.t(), path :: String.t()) :: boolean()
  def beyond_link?(root, path) when is_binary(path) do
    path
    |> Path.dirname()
    |> Path.split()
    |> Enum.reject(&(&1 == "."))
    |> Enum.scan(root, &Path.join(&2, &1))
    |> Enum.any?(&match?({:ok, %File.Stat{type: :symlink}}, File.lstat(&1)))
  end

  defp worktree_entries_in(repository, private, paths) do
    root = repository.root
    stats = Map.new(paths, &{&1, kind(root, &1)})
    files = Enum.filter(paths, &match?({:regular, _mode}, stats[&1]))
    links = Enum.filter(paths, &match?({:symlink, _mode}, stats[&1]))

    with {:ok, hashed} <- hash(private, files) do
      found = Map.merge(hashed, link_blobs(root, links, repository.object_format))

      {:ok,
       Map.new(paths, fn path ->
         case {Map.get(found, path), stats[path]} do
           {nil, _stat} -> {path, nil}
           {blob, {_type, mode}} -> {path, %{mode: mode, blob: blob}}
         end
       end)}
    end
  end

  # A path beyond a symbolic link is not in the work tree (`beyond_link?/2`),
  # so it is neither stat-ed, hashed nor read through the link.
  defp kind(root, path) do
    if beyond_link?(root, path), do: {:absent, nil}, else: kind(Path.join(root, path))
  end

  defp kind(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} -> {:symlink, "120000"}
      {:ok, %File.Stat{type: :regular, mode: mode}} -> {:regular, executable(mode)}
      {:ok, %File.Stat{type: type}} -> {type, nil}
      {:error, _reason} -> {:absent, nil}
    end
  end

  # Git's own rule: the owner's execute bit decides.
  defp executable(mode) when Bitwise.band(mode, 0o100) != 0, do: "100755"
  defp executable(_mode), do: "100644"

  defp hash(_private, []), do: {:ok, %{}}

  defp hash(private, paths) do
    paths
    |> Enum.chunk_every(@add_batch)
    |> Enum.reduce_while({:ok, %{}}, fn batch, {:ok, found} ->
      case hash_batch(private, batch) do
        {:ok, hashed} -> {:cont, {:ok, Map.merge(found, hashed)}}
        error -> {:halt, error}
      end
    end)
  end

  defp hash_batch(private, paths) do
    with {:ok, output} <- Repository.run(private, ["hash-object", "--" | paths]) do
      # Only object names: a warning git writes on the way must not shift which
      # hash is paired with which path.
      hashes =
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&Regex.match?(~r/\A[0-9a-f]{40,64}\z/, &1))

      if length(hashes) == length(paths),
        do: {:ok, paths |> Enum.zip(hashes) |> Map.new()},
        else: {:error, {:hash_object, output}}
    end
  end

  defp link_blobs(root, links, algorithm) do
    Map.new(links, fn link ->
      case File.read_link(Path.join(root, link)) do
        {:ok, target} -> {link, object_id(algorithm, "blob", target)}
        {:error, _reason} -> {link, nil}
      end
    end)
  end

  defp object_id(algorithm, type, contents) do
    algorithm
    |> :crypto.hash("#{type} #{byte_size(contents)}\0" <> contents)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Writes each path's contents from `tree` into the working tree, and nowhere
  else, and answers each path that did not come out as `tree` has it, with
  the reason.

  The private index is empty, so git has no cached stat to trust over the
  file itself (see the moduledoc). Every batch of paths is tried even when
  one fails, and every path is then hashed again: a batch that failed may
  have written some of its paths, and one that succeeded must still be
  checked, so a report says "restored" about exactly the files that were. A
  path a filter attribute names is not written at all, and says so (see
  "Filtered files"). `{:error, reason}` only when what was written could not
  be checked at all, after a batch failed.
  """
  @spec restore(root :: Path.t(), tree :: String.t(), paths :: [String.t()], opts :: keyword()) ::
          {:ok, unwritten :: %{String.t() => String.t()}} | :skipped | {:error, term()}
  def restore(root, tree, paths, opts \\ [])
  def restore(_root, _tree, [], _opts), do: {:ok, %{}}

  def restore(root, tree, paths, opts) do
    with {:ok, repository} <- Repository.locate(root) do
      private = [
        scratch: Keyword.get(opts, :scratch),
        settings: Repository.settings(repository, :work_tree)
      ]

      Repository.with_private(repository, private, &restore_in(repository, &1, tree, paths))
    end
  end

  defp restore_in(repository, private, tree, paths) do
    {refused, plain} = filtered_paths(private, paths)
    failed = restore_batches(private, tree, plain)

    case unwritten_in(repository, private, tree, plain) do
      {:ok, unwritten} ->
        {:ok,
         unwritten
         |> Map.new(&{&1, Map.get(failed, &1, "git restore did not write it")})
         |> Map.merge(refused)}

      # Git said it wrote every one; the check is the second opinion.
      {:error, _reason} when failed == %{} ->
        {:ok, refused}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The paths a filter attribute names, with why they are not written, and
  # the rest. A batch whose attributes could not be read is refused whole:
  # writing a file that may need a filter is the one thing this must not do.
  defp filtered_paths(private, paths) do
    paths
    |> Enum.chunk_every(@add_batch)
    |> Enum.reduce({%{}, []}, fn batch, {refused, plain} ->
      case Repository.run(private, ["check-attr", "-z", "filter", "--" | batch]) do
        {:ok, output} ->
          named = filter_named(output)
          {kept, skipped} = Enum.split_with(batch, &(not MapSet.member?(named, &1)))
          {Map.merge(refused, Map.new(skipped, &{&1, filtered_reason()})), plain ++ kept}

        {:error, reason} ->
          {Map.merge(refused, Map.new(batch, &{&1, failure(reason)})), plain}
      end
    end)
  end

  # `check-attr -z` answers `path\0filter\0value\0` for each path. A value
  # can be empty (`filter=`), so the answer is split at every NUL, never
  # with empty parts dropped, which would pair each later path with another
  # path's value. `unspecified`, `unset` (`-filter`) and `set` (a bare
  # `filter`) name no driver, and such a file is written like any other, as
  # a snapshot stored it (see `filtered/2`).
  defp filter_named(output) do
    output
    |> String.split(<<0>>)
    |> Enum.drop(-1)
    |> Enum.chunk_every(3)
    |> Enum.flat_map(fn
      [path, "filter", value] when value not in ~w(unspecified unset set) -> [path]
      _driverless -> []
    end)
    |> MapSet.new()
  end

  defp filtered_reason,
    do:
      "git passes it through a filter (Git LFS, git-crypt), which undo does not run, so it " <>
        "was not put back"

  defp restore_batches(private, tree, paths) do
    paths
    |> Enum.chunk_every(@add_batch)
    |> Enum.reduce(%{}, fn batch, failed ->
      case Repository.run(private, ["restore", "--source=" <> tree, "--worktree", "--" | batch]) do
        {:ok, _output} -> failed
        {:error, reason} -> Map.merge(failed, Map.new(batch, &{&1, failure(reason)}))
      end
    end)
  end

  defp failure({:git, _status, output}) do
    line = output |> String.split("\n", trim: true) |> List.first("")
    "git restore failed: " <> String.slice(line, 0, 200)
  end

  defp failure(reason), do: "git restore failed: " <> inspect(reason, limit: 5)

  @doc """
  The paths whose working-tree file is not what `tree` holds — different
  contents, missing, or not in `tree` at all.
  """
  @spec unwritten(root :: Path.t(), tree :: String.t(), paths :: [String.t()], opts :: keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def unwritten(root, tree, paths, opts \\ []) do
    work_tree(root, opts, &unwritten_in(&1, &2, tree, paths))
  end

  defp unwritten_in(_repository, _private, _tree, []), do: {:ok, []}

  defp unwritten_in(repository, private, tree, paths) do
    with {:ok, wanted} <- entries_in(private, tree, paths),
         {:ok, now} <- worktree_entries_in(repository, private, paths) do
      wanted = blob_map(wanted)
      now = blob_map(now)
      {:ok, Enum.reject(paths, &(wanted[&1] != nil and now[&1] == wanted[&1]))}
    end
  end

  @doc """
  Every directory `tree` contains, relative to the repository root, so undo
  removes only directories a turn created.
  """
  @spec directories(root :: Path.t(), tree :: String.t(), opts :: keyword()) ::
          {:ok, MapSet.t(String.t())} | {:error, term()}
  def directories(root, tree, opts \\ []) do
    arguments = ["ls-tree", "-r", "-d", "-z", "--name-only", tree]

    with {:ok, output} <- objects(root, opts, &Repository.run(&1, arguments)) do
      {:ok, output |> String.split(<<0>>, trim: true) |> MapSet.new()}
    end
  end

  @doc "Whether an object still exists, which a `git gc` can change."
  @spec object?(root :: Path.t(), object :: String.t(), opts :: keyword()) :: boolean()
  def object?(root, object, opts \\ []) do
    match?({:ok, _output}, objects(root, opts, &Repository.run(&1, ["cat-file", "-e", object])))
  end

  @doc """
  The working tree's state as `git status --porcelain=v1 --branch
  --untracked-files=normal` prints it — the branch and its upstream on the
  first line, then one line per change, and no warning git printed besides
  — read the way a snapshot reads the repository: in a private git
  directory, from a copy of the index, with nothing the repository
  configures run (see the moduledoc).

  Submodules are compared by the commit they are at, not by what is
  changed inside them (`--ignore-submodules=dirty`): asking a submodule
  that runs git in it, under its own configuration.

  For a host that tells the model or a peer what state a repository was in
  (`Lemieux.Extensions.EnvironmentContext`, `Lemieux.A2A.Server`).
  `{:error, :not_a_repository}` outside a work tree, `{:error, :git_not_found}`
  without git. Options: `:scratch`.
  """
  @spec status(cwd :: Path.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, term()}
  def status(cwd, opts \\ []) do
    arguments =
      ~w(status --porcelain=v1 --branch --untracked-files=normal --ignore-submodules=dirty)

    case Repository.locate(cwd) do
      {:ok, repository} ->
        private = [
          scratch: Keyword.get(opts, :scratch),
          index: :copy,
          refs: true,
          settings: Repository.settings(repository, :status)
        ]

        Repository.with_private(repository, private, &status_in(&1, arguments))

      :skipped ->
        {:error, :not_a_repository}

      {:error, _reason} = error ->
        error
    end
  end

  defp status_in(private, arguments) do
    with {:ok, output} <- Repository.run(private, arguments, env: [{"LC_ALL", "C"}]),
         do: {:ok, porcelain(output)}
  end

  # Only the lines porcelain v1 prints: `## ` and the branch, or two status
  # letters, a space and a path (quoted, so on one line). Where standard
  # error joins the answer (see `Lemieux.Checkpoint.Git.Repository`), a
  # warning git wrote — `refname 'HEAD' is ambiguous`, about a ref a command
  # named `HEAD` — read as a change, and as the branch line's place.
  defp porcelain(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.filter(&Regex.match?(~r/\A(## |[ MTADRCU?!]{2} )/, &1))
    |> Enum.map_join(&(&1 <> "\n"))
  end

  @doc """
  The untracked-file limits `snapshot/2` applies with `opts`: the largest file
  it adds, in bytes, and how many it adds at most.
  """
  @spec limits(opts :: keyword()) :: %{bytes: pos_integer(), files: pos_integer()}
  def limits(opts) do
    %{
      bytes: Keyword.get(opts, :max_untracked_bytes, @max_untracked_bytes),
      files: Keyword.get(opts, :max_untracked_files, @max_untracked_files)
    }
  end

  # A git that reads objects and nothing of the work tree. `root` comes from
  # a recorded snapshot; a directory that is no longer a repository is an
  # error the caller reports, like any other.
  defp objects(root, opts, fun) do
    case Repository.locate(root) do
      {:ok, repository} ->
        Repository.with_private(repository, [scratch: Keyword.get(opts, :scratch)], fun)

      :skipped ->
        {:error, :not_a_repository}

      error ->
        error
    end
  end

  # A git that reads the work tree as well: with the settings that decide how
  # its files read.
  defp work_tree(root, opts, fun) do
    case Repository.locate(root) do
      {:ok, repository} ->
        private = [
          scratch: Keyword.get(opts, :scratch),
          settings: Repository.settings(repository, :work_tree)
        ]

        Repository.with_private(repository, private, &fun.(repository, &1))

      :skipped ->
        {:error, :not_a_repository}

      error ->
        error
    end
  end

  # Runs `git <command> -- <paths>` a batch of paths at a time, so a long list
  # never exceeds the operating system's argument limit; stops at the first
  # failure.
  defp in_batches(private, command, paths) do
    paths
    |> Enum.chunk_every(@add_batch)
    |> Enum.reduce_while(:ok, fn batch, :ok ->
      case Repository.run(private, command ++ ["--" | batch]) do
        {:ok, _output} -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # One walk with `--directory`, which names an untracked directory once
  # (`newdir/`) and is the only listing that shows an empty one, then a walk
  # of just those directories for the files inside: the same files a plain
  # `--others` lists, and the directories a tree cannot show, for no second
  # walk of the whole work tree.
  defp add_untracked(root, private, opts) do
    %{bytes: max_bytes, files: max_files} = limits(opts)
    listing = ["ls-files", "-z", "--others", "--exclude-standard"]

    with {:ok, output} <- Repository.run(private, listing ++ ["--directory"]),
         {dirs, files} = output |> String.split(<<0>>, trim: true) |> Enum.split_with(&dir?/1),
         {:ok, inside} <- inside(private, listing, dirs) do
      # Files in directories git tracks come first, then those in directories
      # it does not, each in path order: a bulk untracked directory — a
      # dataset, a cache — then cannot crowd a new file beside the code out
      # of the first 2,000.
      {addable, large} =
        (Enum.sort(files) ++ (inside |> Enum.reject(&dir?/1) |> Enum.sort()))
        |> Enum.flat_map(&untracked(root, &1, max_bytes))
        |> Enum.split_with(&match?({:add, _path, _stat}, &1))

      {added, beyond} = Enum.split(addable, max_files)

      unsaved =
        Enum.map(large, fn {:large, path, stat} -> unsaved(path, stat, :large) end) ++
          Enum.map(beyond, fn {:add, path, stat} -> unsaved(path, stat, :beyond_limit) end)

      with :ok <- in_batches(private, ["add"], Enum.map(added, &elem(&1, 1))),
           do: {:ok, unsaved, dirs}
    end
  end

  defp dir?(path), do: String.ends_with?(path, "/")

  defp inside(_private, _listing, []), do: {:ok, []}

  defp inside(private, listing, dirs) do
    dirs
    |> Enum.chunk_every(@add_batch)
    |> Enum.reduce_while({:ok, []}, fn batch, {:ok, found} ->
      case Repository.run(private, listing ++ ["--" | batch]) do
        {:ok, output} -> {:cont, {:ok, found ++ String.split(output, <<0>>, trim: true)}}
        error -> {:halt, error}
      end
    end)
  end

  # A symbolic link is added as a link, whatever it points at; anything else
  # that is neither a regular file nor a link (a socket, a fifo) is skipped.
  defp untracked(root, path, max_bytes) do
    case File.lstat(Path.join(root, path), time: :posix) do
      {:ok, %File.Stat{type: :symlink} = stat} ->
        [{:add, path, stat}]

      {:ok, %File.Stat{type: :regular, size: size} = stat} when size <= max_bytes ->
        [{:add, path, stat}]

      {:ok, %File.Stat{type: :regular} = stat} ->
        [{:large, path, stat}]

      _other ->
        []
    end
  end

  # The files `.gitignore` excludes one by one, and the wholly ignored
  # directories. `--directory` names `_build/` or `node_modules/` once instead
  # of file by file, which is what keeps this as cheap as the untracked
  # listing above — and why a directory is noted only by being there: undo
  # can say a command deleted `_build/`, not what changed inside it.
  defp ignored(root, private) do
    arguments = ["ls-files", "-z", "--others", "--ignored", "--exclude-standard", "--directory"]

    with {:ok, output} <- Repository.run(private, arguments) do
      {:ok,
       output
       |> String.split(<<0>>, trim: true)
       |> Enum.flat_map(&ignored_entry(root, &1))}
    end
  end

  defp ignored_entry(root, path) do
    case File.lstat(Path.join(root, path), time: :posix) do
      {:ok, %File.Stat{type: :directory}} ->
        [%{path: path, size: 0, mtime: 0, inode: 0, why: :ignored}]

      {:ok, %File.Stat{type: type} = stat} when type in [:regular, :symlink] ->
        [unsaved(path, stat, :ignored)]

      _other ->
        []
    end
  end

  defp unsaved(path, %File.Stat{} = stat, why),
    do: %{path: path, size: stat.size, mtime: stat.mtime, inode: stat.inode, why: why}

  # One `show-ref` for both: the `HEAD` line is the commit, the rest are the
  # refs whose digest says whether any branch, tag, stash or remote-tracking
  # ref moved. Read in the private directory, through links to the
  # repository's refs: a ref pointing at an object a partial clone lacks is
  # then a ref git cannot show, not a fetch. The branch comes from the HEAD
  # file itself, which names it even before its first commit.
  defp refs(repository, private) do
    lines =
      case Repository.run(private, ["show-ref", "--head"]) do
        {:ok, output} -> String.split(output, "\n", trim: true)
        {:error, _no_refs_yet} -> []
      end

    {heads, others} = Enum.split_with(lines, &String.ends_with?(&1, " HEAD"))

    commit =
      case heads do
        [line | _rest] -> line |> String.split(" ") |> hd()
        [] -> nil
      end

    digest = :sha256 |> :crypto.hash(Enum.join(others, "\n")) |> Base.encode16(case: :lower)
    {%{commit: commit, branch: branch(repository.git_dir)}, digest}
  end

  defp branch(git_dir) do
    case File.read(Path.join(git_dir, "HEAD")) do
      {:ok, "ref: refs/heads/" <> name} -> String.trim(name)
      {:ok, "ref: " <> ref} -> String.trim(ref)
      _detached_or_unreadable -> nil
    end
  end

  defp changes(pairs) do
    Enum.flat_map(pairs, fn
      ["A", path] -> [{:added, path}]
      ["D", path] -> [{:deleted, path}]
      [status, path] when status in ["M", "T"] -> [{:modified, path}]
      _other -> []
    end)
  end
end
