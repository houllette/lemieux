defmodule Lemieux.Tools.Write do
  @moduledoc """
  Writes a file, creating its parent directories.

  ## Creating the parents

  `mkdir -p` rather than an error, because the alternative is a model that has
  to run `bash mkdir -p` before every new file in a new directory — a whole
  extra round trip to the model, every time, to say something it already
  said by giving the path.

  ## Saying that it overwrote

  The result distinguishes creating from replacing. It is the same call either
  way, and a model that believes it created a file it actually destroyed will
  not go looking for what used to be there. Naming it in the result is the
  cheapest possible correction, and it costs one word.

  ## Not replacing what was never read

  In a session, an existing file is replaced only if the session has seen it
  — read it, written it, or edited it — and it has not changed since (see
  `Lemieux.Tool.FileState`). Otherwise the write is refused and the model is
  told to read the file first. A whole-file write from memory is how a user's
  unsaved change, a formatter's output or the three hundred lines the model
  never looked at disappear without a trace in the transcript; one `read` is
  the whole price of not doing that. Writing exactly what the file already
  holds is allowed, since it replaces nothing.

  A tool called outside a session (a context with no session to keep a
  record) writes as it always did. There is no confirmation prompt here and no
  backup copy: approval is the host's job, through `before_tool_call`. See
  `Lemieux.Hooks`.
  """

  @behaviour Lemieux.Tool

  alias Lemieux.Environment
  alias Lemieux.Tool.FileState

  @impl Lemieux.Tool
  def name, do: "write"

  @impl Lemieux.Tool
  def description do
    """
    Write a file, replacing it if it exists. Parent directories are created as
    needed. Prefer edit for changing part of an existing file: write replaces
    the whole thing. An existing file must have been read in this session, and
    be unchanged since, before write will replace it.
    """
  end

  @impl Lemieux.Tool
  def schema do
    %{
      "type" => "object",
      "properties" => %{
        "path" => %{
          "type" => "string",
          "description" => "Path relative to the working directory."
        },
        "content" => %{"type" => "string", "description" => "The file's complete new contents."}
      },
      "required" => ["path", "content"],
      "additionalProperties" => false
    }
  end

  @impl Lemieux.Tool
  def metadata do
    %{
      effects: %{class: "write", resource_types: ["file"]},
      runtime: %{concurrency: %{class: "exclusive"}}
    }
  end

  @impl Lemieux.Tool
  def run(%{"path" => path, "content" => content}, context)
      when is_binary(path) and is_binary(content) do
    environment = Environment.from_context(context)

    case existing(environment, context, path) do
      {:ok, ^content} ->
        FileState.record(context, path, FileState.fingerprint(content))
        {:ok, "#{path} already has exactly this content (#{byte_size(content)} bytes); unchanged"}

      {:ok, current} ->
        with :ok <- may_replace(context, path, current),
             do: write(environment, context, path, content)

      :absent ->
        write(environment, context, path, content)

      {:error, _message} = error ->
        error
    end
  end

  def run(%{"path" => _path}, _context), do: {:error, "write needs content"}
  def run(_args, _context), do: {:error, "write needs a path and content"}

  # What is at `path` now. A file that cannot be read for any other reason is
  # left for the write itself to report: it may well be writable.
  defp existing(environment, context, path) do
    case Environment.read_file(environment, context.cwd, path) do
      {:ok, current} -> {:ok, current}
      {:error, :outside_worktree} -> {:error, "#{path}: is outside the working directory"}
      {:error, :eisdir} -> {:error, "#{path}: is a directory, not a file"}
      {:error, _enoent_or_unreadable} -> :absent
    end
  end

  defp may_replace(context, path, current) do
    case FileState.seen(context, path) do
      :untracked ->
        :ok

      :unseen ->
        {:error,
         "#{path} already exists and has not been read in this session. Read it first — or " <>
           "use edit to change part of it — so that writing does not replace content you " <>
           "have not seen."}

      {:ok, fingerprint} ->
        if fingerprint == FileState.fingerprint(current),
          do: :ok,
          else:
            {:error,
             "#{path} has changed since this session last read or wrote it (another " <>
               "process, a formatter or a person edited it). Read it again before replacing it."}
    end
  end

  defp write(environment, context, path, content) do
    case Environment.write_file(environment, context.cwd, path, content) do
      {:ok, disposition} ->
        FileState.record(context, path, FileState.fingerprint(content))
        {:ok, "#{verb(disposition)} #{path} (#{byte_size(content)} bytes)"}

      {:error, :outside_worktree} ->
        {:error, "#{path}: is outside the working directory"}

      {:error, reason} ->
        {:error, "#{path}: #{:file.format_error(reason)}"}
    end
  end

  defp verb(:overwritten), do: "overwrote"
  defp verb(:created), do: "wrote"
end
