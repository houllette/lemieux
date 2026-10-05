defmodule Lemieux.CLI.SessionIndex do
  @moduledoc """
  The small, human-readable session catalog used by interactive pickers and
  `lmx --continue`.

  A store deliberately promises only append, read and list. That keeps the
  core usable over a filesystem or a host database, but it also means a picker
  cannot ask for a provider-specific query such as "the newest fifty with
  their titles". This module builds that view from the behaviour instead.

  The first user message is the preview because it is normally the task that
  named the session. The last message is often an incidental follow-up such as
  "run the tests", which makes a poor title when returning a day later.

  ## Last activity, from an index rather than from every transcript

  Sessions are ordered by when they were last written to, which is the order
  somebody coming back to their work wants: the conversation they had this
  morning, not the one they happened to start first. For `Lemieux.Store.JSONL`
  that is each file's modification time, which costs a `stat` per session
  rather than reading it. What a picker shows — preview, model, working
  directory — still needs the transcript, so it is kept in `index.json` in the
  sessions directory, keyed by the transcript's size and modification time: a
  session that has not changed since it was indexed is not read again, and one
  that has is read once and re-indexed. Starting `lmx` used to decode fifty
  transcripts before the first session was ready; now it decodes the ones
  that changed. The index is a cache: missing, stale or unreadable, it is
  rebuilt from the transcripts, lazily, as sessions are asked for — which is
  also how sessions written before it existed are picked up.

  A store other than JSONL has no modification time to read, so there the
  newest sessions by the store's own order are read, as before, and the last
  entry's timestamp stands in for last activity.

  ## Delegated children are read and then left out

  A subagent's session is an ordinary session in the same store, so a
  delegation of three put three transcripts in front of the newest fifty —
  and nobody resumes a conversation they never had. They are excluded here,
  by `Lemieux.Transcript.delegated?/2`, which costs nothing extra: the
  transcript was read anyway to get a preview out of it.

  Excluded from the *offer*, and from nothing else. A child's transcript is
  worth reading when a delegation went wrong, so resuming one by id still
  works, and `lmx log` never filtered anything.
  """

  alias Lemieux.Entry
  alias Lemieux.ID.Shorthand
  alias Lemieux.Store
  alias Lemieux.Store.JSONL
  alias Lemieux.Transcript

  @default_limit 50
  @index_file "index.json"
  @index_version 1

  @type t :: %__MODULE__{
          id: String.t(),
          shorthand: String.t() | nil,
          at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          model: String.t() | nil,
          cwd: Path.t() | nil,
          preview: String.t() | nil
        }

  @enforce_keys [:id]
  defstruct [:id, :shorthand, :at, :updated_at, :model, :cwd, :preview]

  @doc """
  Returns the stored sessions a person might resume, most recently active
  first.

  An initialized session with no prompt or agent activity is not a history
  item. Starting the TUI and immediately resuming another session writes its
  configuration, but offering that empty file as a conversation gives the
  picker a blank row and can push a real session past its limit. Files remain
  untouched so store-level recovery and auditing still see them.

  A transcript that disappears between listing and reading is skipped. One
  this build cannot read — written by a different version of lemieux — is
  listed and labelled as such: it is a real session, the person may well be
  looking for it, and one foreign file in `~/.lmx/sessions` must not be able
  to empty the picker. Any other store failure is returned, because
  presenting a partial picker as complete would hide a real persistence
  problem.

  Options:

    * `:limit` — how many to return (default 50);
    * `:cwd` — only sessions that ran in this directory.
  """
  @spec recent(store :: Store.t(), opts :: keyword()) :: {:ok, [t()]} | {:error, term()}
  def recent({JSONL, %{dir: dir}} = store, opts) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(0)
    walk = %{store: store, limit: limit, cwd: cwd_filter(opts)}

    dir
    |> stamped_ids()
    |> Enum.sort_by(fn {id, stamp} -> {stamp.mtime, id} end, :desc)
    |> Enum.reduce_while({:ok, [], read_index(dir), false}, &visit(walk, &1, &2))
    |> case do
      {:ok, found, index, changed?} ->
        if changed?, do: write_index(dir, index)
        {:ok, Enum.reverse(found)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def recent(store, opts) when is_list(opts) do
    limit = opts |> Keyword.get(:limit, @default_limit) |> max(0)
    cwd = cwd_filter(opts)

    with {:ok, ids} <- Store.list_sessions(store) do
      ids
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, []}, &read_until_limit(store, limit, cwd, &1, &2))
      |> then(fn
        {:ok, sessions} ->
          {:ok, sessions |> Enum.reverse() |> Enum.sort_by(&sort_key/1, :desc)}

        error ->
          error
      end)
    end
  end

  @doc """
  The same list, addressed by options alone, for callers that have a
  sessions directory rather than a store: `:dir` (or `:store`), `:cwd` and
  `:limit`. Returns `[]` when the store cannot be read, since a picker has
  nothing better to show.
  """
  @spec recent(store_or_opts :: Store.t() | keyword()) :: {:ok, [t()]} | {:error, term()} | [t()]
  def recent(store) when is_tuple(store), do: recent(store, [])

  def recent(opts) when is_list(opts) do
    store =
      Keyword.get_lazy(opts, :store, fn ->
        opts |> Keyword.fetch!(:dir) |> Path.expand() |> JSONL.new()
      end)

    case recent(store, Keyword.take(opts, [:cwd, :limit])) do
      {:ok, sessions} -> sessions
      {:error, _reason} -> []
    end
  end

  @doc """
  The id of the session that most recently ran in `cwd`, or `nil`.

  What `lmx --continue` resumes.
  """
  @spec latest(store :: Store.t(), cwd :: Path.t()) :: String.t() | nil
  def latest(store, cwd) when is_binary(cwd) do
    case recent(store, cwd: cwd, limit: 1) do
      {:ok, [%__MODULE__{id: id} | _rest]} -> id
      _none -> nil
    end
  end

  # One transcript, newest first, until the limit is reached: served from the
  # index when unchanged, read and re-indexed when not.
  defp visit(%{limit: limit}, _stamped, {:ok, found, _index, _changed?} = acc)
       when length(found) >= limit,
       do: {:halt, acc}

  defp visit(walk, {id, stamp}, {:ok, found, index, changed?}) do
    case indexed(walk.store, id, stamp, index) do
      {:ok, entry, fresh?} ->
        found = if offered?(entry, walk.cwd), do: [from_index(entry) | found], else: found
        {:cont, {:ok, found, Map.put(index, id, entry), changed? or fresh?}}

      :gone ->
        {:cont, {:ok, found, Map.delete(index, id), true}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  defp read_until_limit(_store, limit, _cwd, _id, {:ok, sessions} = acc)
       when length(sessions) >= limit,
       do: {:halt, acc}

  defp read_until_limit(store, _limit, cwd, id, {:ok, sessions}) do
    case Store.read(store, id) do
      {:ok, entries} ->
        entry = summary(id, entries, nil)
        sessions = if offered?(entry, cwd), do: [from_index(entry) | sessions], else: sessions
        {:cont, {:ok, sessions}}

      {:error, :not_found} ->
        {:cont, {:ok, sessions}}

      {:error, {:unreadable, _id, _reason}} ->
        entry = unreadable(id, nil)
        sessions = if offered?(entry, cwd), do: [from_index(entry) | sessions], else: sessions
        {:cont, {:ok, sessions}}

      {:error, reason} ->
        {:halt, {:error, reason}}
    end
  end

  @doc """
  A compact label for a completion list.

  Led by the shorthand rather than the id, because the label's job is to hand
  somebody something to type next and nobody retypes a ULID. The id is still
  the identity and is still what the picker resolves to; it is just not what
  the line is for.
  """
  @spec label(session :: t()) :: String.t()
  def label(%__MODULE__{} = session) do
    [date(session.at), session.model, quoted(session.preview)]
    |> Enum.reject(&is_nil/1)
    |> then(&Enum.join([shorthand(session) | &1], " · "))
  end

  @doc "The rememberable name for a session, whether or not the struct carries one."
  @spec shorthand(session :: t()) :: String.t()
  def shorthand(%__MODULE__{shorthand: shorthand}) when is_binary(shorthand), do: shorthand
  def shorthand(%__MODULE__{id: id}), do: Shorthand.of(id)

  # --- The index --------------------------------------------------------------

  # Every transcript in the directory with what identifies its current
  # contents. A file that vanished between the listing and its `stat` is left
  # out here rather than failing the picker.
  defp stamped_ids(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        for name <- names,
            Path.extname(name) == ".jsonl",
            {:ok, stat} <- [File.stat(Path.join(dir, name), time: :posix)],
            do: {Path.basename(name, ".jsonl"), %{mtime: stat.mtime, size: stat.size}}

      {:error, _reason} ->
        []
    end
  end

  defp indexed(store, id, stamp, index) do
    case Map.get(index, id) do
      %{"mtime" => mtime, "size" => size} = entry
      when mtime == stamp.mtime and size == stamp.size ->
        {:ok, entry, false}

      _stale_or_missing ->
        read_entry(store, id, stamp)
    end
  end

  defp read_entry(store, id, stamp) do
    case Store.read(store, id) do
      {:ok, entries} ->
        {:ok, stamped(summary(id, entries, stamp.mtime), stamp), true}

      {:error, :not_found} ->
        :gone

      {:error, {:unreadable, _id, _reason}} ->
        {:ok, stamped(unreadable(id, stamp.mtime), stamp), true}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stamped(entry, stamp),
    do: Map.merge(entry, %{"mtime" => stamp.mtime, "size" => stamp.size})

  # What the index keeps for one transcript: JSON-shaped, so the file is
  # readable and survives a build that changes this struct.
  defp summary(id, entries, mtime) do
    session = entries |> Enum.filter(&(&1.type == :session)) |> List.last()

    %{
      "id" => id,
      "at" => entries |> List.first() |> entry_at() |> iso(),
      "updated_at" => updated_at(entries, mtime),
      "model" => payload_string(session, "model"),
      "cwd" => payload_string(session, "cwd"),
      "preview" => entries |> Enum.find(&(&1.type == :user)) |> preview(),
      "offered" => not Transcript.delegated?(entries, id) and substantive?(entries)
    }
  end

  defp unreadable(id, mtime) do
    %{
      "id" => id,
      "at" => nil,
      "updated_at" => if(mtime, do: iso(DateTime.from_unix!(mtime))),
      "model" => nil,
      "cwd" => nil,
      "preview" => "unreadable — written by another version of lemieux",
      "offered" => true
    }
  end

  defp updated_at(_entries, mtime) when is_integer(mtime), do: iso(DateTime.from_unix!(mtime))
  defp updated_at(entries, nil), do: entries |> List.last() |> entry_at() |> iso()

  defp offered?(%{"offered" => false}, _cwd), do: false
  defp offered?(_entry, nil), do: true
  defp offered?(%{"cwd" => cwd}, wanted) when is_binary(cwd), do: Path.expand(cwd) == wanted
  defp offered?(_entry, _wanted), do: false

  defp cwd_filter(opts) do
    case Keyword.get(opts, :cwd) do
      nil -> nil
      cwd -> Path.expand(cwd)
    end
  end

  defp from_index(entry) do
    %__MODULE__{
      id: entry["id"],
      shorthand: Shorthand.of(entry["id"]),
      at: datetime(entry["at"]),
      updated_at: datetime(entry["updated_at"]),
      model: entry["model"],
      cwd: entry["cwd"],
      preview: entry["preview"]
    }
  end

  defp sort_key(%__MODULE__{updated_at: nil, id: id}), do: {0, id}
  defp sort_key(%__MODULE__{updated_at: at, id: id}), do: {DateTime.to_unix(at), id}

  defp read_index(dir) do
    with {:ok, content} <- File.read(Path.join(dir, @index_file)),
         {:ok, %{"version" => @index_version, "sessions" => %{} = sessions}} <-
           JSON.decode(content) do
      sessions
    else
      _missing_or_stale -> %{}
    end
  end

  # Advisory: a sessions directory another process is writing, or one the
  # person cannot write, leaves the index as it was and the picker correct.
  defp write_index(dir, sessions) do
    path = Path.join(dir, @index_file)
    temporary = path <> "." <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)
    document = JSON.encode!(%{"version" => @index_version, "sessions" => sessions})

    try do
      with :ok <- File.write(temporary, document, [:exclusive]),
           :ok <- File.chmod(temporary, 0o600) do
        File.rename(temporary, path)
      end
    after
      File.rm(temporary)
    end
  end

  # --- Reading one transcript ---------------------------------------------------

  defp substantive?(entries),
    do: Enum.any?(entries, &(&1.type in [:user, :assistant, :tool_call, :tool_result]))

  defp entry_at(%Entry{at: at}), do: at
  defp entry_at(nil), do: nil

  defp payload_string(%Entry{payload: payload}, key) do
    case Map.get(payload, key) do
      value when is_binary(value) -> value
      _other -> nil
    end
  end

  defp payload_string(nil, _key), do: nil

  defp preview(%Entry{payload: %{"text" => text}}) when is_binary(text) do
    text |> String.replace(~r/\s+/, " ") |> String.trim() |> String.slice(0, 72)
  end

  defp preview(_entry), do: nil

  defp iso(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp iso(nil), do: nil

  defp datetime(nil), do: nil

  defp datetime(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _invalid -> nil
    end
  end

  defp date(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp date(nil), do: nil

  defp quoted(nil), do: nil
  defp quoted(text), do: "“#{text}”"
end
