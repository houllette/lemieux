defmodule Lemieux.Reference do
  @moduledoc """
  An `@path` a person typed into a prompt, before anybody has read it.

  Parsing is separated from resolving on purpose. `parse/1` is a pure function
  over a string — a list in, a list out — so every question about the grammar
  ("is `user@example.com` a reference?", "does a full stop end the sentence or
  the filename?") is answered by a test that runs in microseconds and says
  which rule decided. `resolve/4` is the other half, and it is the one that
  needs an environment, a working directory and a byte budget.

  ## The two kinds of reference, and why the distinction is load-bearing

  This is a repository full of Elixir, and people paste Elixir into prompts.
  A pasted module is a hail of `@moduledoc`, `@spec`, `@impl` and `@type`, and
  a naive parser reports every one of them as a file that could not be found.
  The prompt then arrives carrying a dozen apologies about missing files,
  which is worse than not having the feature.

  So a reference is one of two things:

    * **explicit** — it committed to being a path. It contains a separator
      (`@lib/turn.ex`), or it was quoted (`@"my file.ex"`), or it ends in
      something that reads like a real extension (`@README.md`). Failing to
      resolve one of these is worth telling the model about: the person meant
      a file and did not get it.
    * **ambiguous** — a bare word, like `@spec` or `@Makefile`. Resolve it if
      it happens to name a file, and say nothing at all if it does not.

  The extension test deliberately rejects a digit-led suffix, so "bump to
  `@1.2.3`" is ambiguous rather than a missing file called `1.2.3`.

  A consequence for whoever writes the resolver: an ambiguous reference must
  never expand to a *directory*. `@test` in a pasted snippet would otherwise
  attach this repository's entire test tree, which is the same failure the
  distinction exists to prevent, arriving by a different door. A directory
  has to be asked for explicitly — `@test/` or `@./test`.

  ## MCP resources: `@server:uri`

  A connected MCP server may offer resources — a document, a record, a log —
  named by a URI of its own. `@docs:file:///guide.md` asks for the resource
  `file:///guide.md` from the server `docs`. The form is strict on purpose:
  the part after the server's name must be a URI with a scheme
  (`letters:` then more), so `@README.md: it says…` stays a reference to the
  file and the sentence goes on, and `@10:30:00` is not a server called `10`.
  A path with a colon in it is quoted, as any unusual path is: `@"a:b.txt"`.

  A resource reference is always explicit — nobody types a server's name and
  a URI by accident — and it is resolved by whoever holds the server's
  connection, through the `:resource` option of `resolve/4`. The byte budget
  is the one files spend: a resource is text in a `:user` entry like any
  other attachment, re-sent for the rest of the conversation.

  ## Resolving reads through the environment, never through `File`

  `resolve/4` goes through `Lemieux.Environment`, which is what confines a
  reference to the session's working directory and what lets a host point the
  whole thing at a container or a remote workspace. The obvious shortcut —
  `File.read/1`, since the CLI is running on the machine anyway — would read
  the host's filesystem for a session whose tools are sandboxed elsewhere, and
  the prompt would then describe files the agent cannot act on.

  ## Budgets, and why a failure is still an attachment

  Two caps. A per-reference one bounds any single file, and a per-prompt one
  bounds the lot: an attachment rides in a `:user` entry, and a `:user` entry
  is re-sent on every request for the rest of the conversation, so an
  unbounded one is not a large prompt but a permanently large session.

  When an explicit reference cannot be read — missing, outside the working
  directory, or arriving after the budget is gone — the result is an
  attachment that *says so*, not a silent omission. This is the same rule
  `Lemieux.Hooks` documents for a denied tool call: an agent that is never
  told the file is missing carries on as though it had it, and everything
  after that point is quietly wrong.

  ## Escaping

  `\\@lib/turn.ex` is not a reference. The backslash stays in the prompt text
  rather than being stripped, because the text of a `:user` entry is what the
  person typed and rewriting it would make the transcript disagree with them.
  A stray backslash the model can see is a smaller lie than a prompt nobody
  sent.
  """

  alias Lemieux.Environment
  alias Lemieux.Tool

  @typedoc """
  One reference, as typed.

    * `raw` — the exact substring matched, `@` and quotes included. What a
      front end highlights, and what correlates an attachment back to the
      prose that mentioned it.
    * `path` — the path it names, unquoted and stripped of sentence
      punctuation. Not resolved, not checked, and possibly not even inside the
      working directory: that is the environment's judgement to make.
    * `quoted?` — whether it arrived in the `@"..."` form.
    * `explicit?` — whether failing to resolve it is worth reporting. See the
      module documentation.
    * `kind` — `:path` for a file, directory or glob; `:resource` for an MCP
      server's resource, typed `@server:uri`.
    * `server` and `uri` — which server and which of its resources, for a
      `:resource`; `nil` otherwise. `path` is then `server:uri`, the form
      that was typed.
  """
  @type t :: %__MODULE__{
          raw: String.t(),
          path: String.t(),
          quoted?: boolean(),
          explicit?: boolean(),
          kind: :path | :resource,
          server: String.t() | nil,
          uri: String.t() | nil
        }

  @enforce_keys [:raw, :path, :quoted?, :explicit?]
  defstruct [:raw, :path, :quoted?, :explicit?, kind: :path, server: nil, uri: nil]

  # The negative lookbehind is the whole email defence: an `@` is only a reference
  # at the start of the text or after whitespace or an opening bracket. Written as
  # "not one of the disallowed characters" rather than a positive class so that it
  # is a single fixed-width assertion, which is what lets it succeed at offset zero.
  # `*` is in the unquoted class because a glob is a reference too; `?` and `[` are
  # not, because they collide with sentence punctuation, and a name that needs them
  # can be quoted.
  @path_chars "A-Za-z0-9._/~+*-"
  # An MCP resource: a server's name, a colon, and a URI with a scheme. It is
  # the second alternative, tried before the path, so `@docs:file:///x` is one
  # reference rather than the path `docs` and some prose after it; when what
  # follows the colon is not a URI, the path alternative takes the name alone,
  # exactly as it did before resources existed.
  @server_chars "A-Za-z0-9_.-"
  @uri "[A-Za-z][A-Za-z0-9+.-]*:[^\\s\"'<>`]+"
  @pattern ~r/(?<![^\s(\[{<'"`])@(?:"([^"\n]+)"|([#{@server_chars}]+):(#{@uri})|([#{@path_chars}]+))/
  @unquoted ~r/^[#{@path_chars}]+$/
  # What is left of a URI once sentence punctuation is trimmed must still be a
  # scheme and something after it.
  @whole_uri ~r/^[A-Za-z][A-Za-z0-9+.-]*:.+$/
  @closers %{")" => "(", "]" => "[", "}" => "{"}

  # A suffix worth calling an extension starts with a letter. `.md` and `.ex`
  # qualify; the `.3` of a version number does not.
  @extension ~r/^\.[A-Za-z][A-Za-z0-9]{0,9}$/

  @doc """
  Finds every `@path` in a prompt, in the order they were typed.

  The same path referenced twice is one reference, keeping the first spelling
  of it — two attachments of one file would cost the window twice and give the
  model two things to disagree about.

      iex> Lemieux.Reference.parse("explain @lib/lemieux/turn.ex")
      [%Lemieux.Reference{
         raw: "@lib/lemieux/turn.ex",
         path: "lib/lemieux/turn.ex",
         quoted?: false,
         explicit?: true
       }]

      iex> Lemieux.Reference.parse("mail someone@example.com about it")
      []
  """
  @spec parse(text :: String.t()) :: [t()]
  def parse(text) when is_binary(text) do
    @pattern
    |> Regex.scan(text)
    |> Enum.flat_map(&reference/1)
    |> Enum.uniq_by(& &1.path)
  end

  # The captures arrive by alternative: the quoted path, then a server and a
  # URI, then the unquoted path. A group that did not take part is empty, and
  # the trailing ones are not reported at all.
  defp reference([raw, quoted]) when quoted != "", do: [build(raw, quoted, true)]
  defp reference([_raw, "", server, uri]) when server != "", do: resource(server, uri)
  defp reference([raw, "", "", "", unquoted]), do: unquoted(raw, unquoted)
  defp reference(_no_capture), do: []

  defp unquoted(raw, unquoted) do
    case String.replace(unquoted, ~r/\.+$/, "") do
      "" -> []
      path -> [build(trim_raw(raw, unquoted, path), path, false)]
    end
  end

  # Sentence punctuation after a URI belongs to the sentence, as the full stop
  # after a path does. What remains must still be a URI; `@name:x:.` was a
  # colon too many in a sentence, and reads the way it always did — as the
  # reference `@name`.
  defp resource(server, uri) do
    trimmed = trim_uri(uri)

    if Regex.match?(@whole_uri, trimmed),
      do: [
        %__MODULE__{
          raw: "@" <> server <> ":" <> trimmed,
          path: server <> ":" <> trimmed,
          quoted?: false,
          explicit?: true,
          kind: :resource,
          server: server,
          uri: trimmed
        }
      ],
      else: unquoted("@" <> server, server)
  end

  # A closing bracket is the sentence's only when nothing in the URI opened it:
  # `(see @docs:mem://a)` ends at `a`, while `@docs:mem://f(x)` keeps its `)`.
  defp trim_uri(uri) do
    trimmed = String.replace(uri, ~r/[.,;:!?]+$/, "")

    case unbalanced_close(trimmed) do
      nil -> trimmed
      shorter -> trim_uri(shorter)
    end
  end

  defp unbalanced_close(uri) do
    closer = String.last(uri)

    with opener when is_binary(opener) <- Map.get(@closers, closer),
         true <- occurrences(uri, closer) > occurrences(uri, opener) do
      String.slice(uri, 0..-2//1)
    else
      _balanced -> nil
    end
  end

  defp occurrences(text, char), do: length(String.split(text, char)) - 1

  defp build(raw, path, quoted?) do
    %__MODULE__{
      raw: raw,
      path: path,
      quoted?: quoted?,
      explicit?: quoted? or explicit?(path)
    }
  end

  # `raw` is what the front end will highlight, so the full stop that was
  # dropped from the path has to be dropped from it too.
  defp trim_raw(raw, unquoted, path) when unquoted == path, do: raw
  defp trim_raw(_raw, _unquoted, path), do: "@" <> path

  defp explicit?(path),
    do: String.contains?(path, "/") or Regex.match?(@extension, Path.extname(path))

  @typedoc """
  One resolved reference, JSON-shaped so it can live in a `:user` payload.

    * `"ref"` — the reference as typed, `@` included, so an attachment can be
      pointed back at the prose that asked for it.
    * `"path"` — the path it named.
    * `"kind"` — `"file"` for something read, `"error"` for something that
      could not be.
    * `"text"` — exactly what the model should see. Composed here rather than
      at the provider seam so that the wording is settled by a pure test
      instead of by whichever adapter is in use.
    * `"bytes"` — what `"text"` costs, which is what the budget spends.
  """
  @type attachment :: %{String.t() => String.t() | non_neg_integer()}

  # The same ceiling `Lemieux.Tools.Read` puts on a single read. A file is no
  # more affordable because a person named it than because the model did.
  @max_bytes 60_000

  # And a ceiling on the prompt as a whole, which the per-file cap alone does
  # not give: ten references at the maximum would be ten times too much.
  @budget 200_000

  # How much of a directory is worth attaching. A generated tree is not more
  # interesting for being large, and the byte cap alone would cut the listing
  # mid-name without saying how many were left.
  @max_entries 1_000

  # What a file's own bytes may be sent as, keyed by the only clue available without
  # reading it — sniffing magic bytes would be more accurate and would mean reading a
  # file before deciding whether it is small enough to read. The image types are the
  # four every provider in `req_llm` accepts. PDFs go as documents, which Anthropic
  # takes and OpenAI's own guard rejects, so the failure names the file.
  @media_types %{
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".pdf" => "application/pdf",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }

  # Roughly Anthropic's ceiling once base64 has added its third. A file over
  # it is refused here rather than at the provider, because the provider's
  # answer to an oversized image is a 400 for the whole request — including
  # the conversation that was fine.
  @max_image_bytes 3_500_000

  # About what a provider charges for one image. Flat on purpose — see
  # `estimable/1`.
  @image_tokens 1_600

  # How many files one glob may attach. The byte budget bounds what they cost
  # together; this bounds how many separate things the model is handed, which
  # a thousand one-line files would otherwise make unreadable.
  @max_glob_matches 25

  # How many directories a walk may list. A glob crossing `node_modules` is
  # not a reason to read a hundred thousand directories in front of somebody
  # waiting for their prompt to be sent.
  @max_glob_dirs 500

  # Bytes are counted against a separate allowance from text, because they are
  # not comparable: an image costs the model something like a page of prose,
  # not the megabyte it takes on disk. Charging it against the text budget
  # would mean one screenshot silently swallowing every other attachment.
  @max_images 5

  @doc """
  Reads what `refs` name, in order, and returns them as durable attachments.

  Ambiguous references — see the module documentation — are dropped when they
  cannot be read. Explicit ones become an `"error"` attachment instead, on the
  grounds that somebody meant a file and should be told they did not get it.

  ## Options

    * `:max_bytes` — the ceiling on one attachment. Defaults to
      `#{@max_bytes}`.
    * `:budget` — the ceiling on all of them together. Defaults to
      `#{@budget}`.
    * `:max_entries` — how many entries of a directory to list. Defaults to
      `#{@max_entries}`.
    * `:max_images` — how many files may ride as their own bytes. Defaults to
      `#{@max_images}`.
    * `:max_image_bytes` — the ceiling on one of those. Defaults to
      `#{@max_image_bytes}`.
    * `:max_glob_matches` — how many files one glob may attach. Defaults to
      `#{@max_glob_matches}`.
    * `:max_glob_dirs` — how many directories a glob may list. Defaults to
      `#{@max_glob_dirs}`.
    * `:resource` — reads an MCP resource, as
      `(server, uri -> {:ok, text} | {:error, :unknown_server | term()})`.
      The session passes one over its connected servers. Without it, a
      `@server:uri` reference becomes an attachment saying it could not be
      read here.
  """
  @spec resolve(
          refs :: [t()],
          environment :: Environment.t(),
          cwd :: Path.t(),
          opts :: keyword()
        ) :: [attachment()]
  def resolve(refs, environment, cwd, opts \\ []) when is_list(refs) and is_list(opts) do
    reader = %{
      environment: environment,
      cwd: cwd,
      max_bytes: Keyword.get(opts, :max_bytes, @max_bytes),
      max_entries: Keyword.get(opts, :max_entries, @max_entries),
      max_images: Keyword.get(opts, :max_images, @max_images),
      max_image_bytes: Keyword.get(opts, :max_image_bytes, @max_image_bytes),
      max_glob_matches: Keyword.get(opts, :max_glob_matches, @max_glob_matches),
      max_glob_dirs: Keyword.get(opts, :max_glob_dirs, @max_glob_dirs),
      resource: Keyword.get(opts, :resource)
    }

    left = %{bytes: Keyword.get(opts, :budget, @budget), images: reader.max_images}

    refs
    |> Enum.flat_map_reduce(left, &spend(&1, reader, &2))
    |> elem(0)
  end

  defp spend(%__MODULE__{kind: :resource} = ref, reader, left),
    do: spend_resource(ref, reader, left)

  defp spend(%__MODULE__{path: path} = ref, reader, left) do
    if String.contains?(path, "*"),
      do: spend_glob(ref, reader, left),
      else: spend_one(ref, reader, left)
  end

  # A resource is text a server holds, spending the allowance files spend: it
  # rides in the same `:user` entry and is re-sent with it just the same.
  defp spend_resource(ref, _reader, %{bytes: bytes} = left) when bytes <= 0,
    do: {refused(ref, "the prompt's attachment budget was already spent"), left}

  defp spend_resource(ref, %{resource: nil}, left),
    do: {refused(ref, "MCP resources cannot be read here"), left}

  defp spend_resource(ref, reader, left) do
    case reader.resource.(ref.server, ref.uri) do
      {:ok, text} when is_binary(text) ->
        body = resource_body(ref, text, min(reader.max_bytes, left.bytes))
        attachment = attachment(ref, "resource", body)
        {[attachment], %{left | bytes: left.bytes - attachment["bytes"]}}

      {:error, reason} ->
        {refused(ref, resource_error(ref, reason)), left}
    end
  end

  defp resource_error(ref, :unknown_server), do: "no connected MCP server is called #{ref.server}"
  defp resource_error(_ref, reason) when is_binary(reason), do: attribute(reason)
  defp resource_error(_ref, reason), do: attribute(inspect(reason))

  # A server's error text lands inside an attribute the model reads; a quote
  # in it would end the attribute early, and a paragraph would be a paragraph.
  defp attribute(text) do
    text
    |> String.replace(~s("), "'")
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 300)
  end

  # Numbered like a file, so the model cites a resource's lines the same way;
  # `kind` is stated because a resource is not a file it could read again.
  defp resource_body(ref, "", _limit),
    do: "<attachment path=\"#{ref.path}\" kind=\"resource\" note=\"is empty (0 bytes)\" />"

  defp resource_body(ref, text, limit) do
    numbered =
      text
      |> Tool.sanitize()
      |> Tool.split_lines()
      |> Tool.number_lines(1)
      |> Tool.truncate(limit)

    ~s(<attachment path="#{ref.path}" kind="resource">\n) <> numbered <> "\n</attachment>"
  end

  # An ambiguous glob is not a glob. `@*` in "multiply by @* please" would
  # otherwise list the working directory.
  defp spend_glob(%__MODULE__{explicit?: false}, _reader, left), do: {[], left}

  defp spend_glob(ref, reader, left) do
    case matches(ref, reader) do
      [] ->
        {refused(ref, "matched no files"), left}

      paths ->
        {attachments, left} =
          paths
          |> Enum.take(reader.max_glob_matches)
          |> Enum.map(&%{ref | path: &1})
          |> Enum.flat_map_reduce(left, &spend_one(&1, reader, &2))

        {attachments ++ capped(ref, length(paths), reader.max_glob_matches), left}
    end
  end

  # A cap nobody is told about reads as "that is all there was".
  defp capped(_ref, matched, allowed) when matched <= allowed, do: []

  defp capped(ref, matched, allowed),
    do: refused(ref, "matched #{matched} files; the first #{allowed} were attached")

  # Walked through `list_dir/3` rather than `Path.wildcard/1` so a glob works in
  # whatever environment the session was given. A `glob` callback on
  # `Lemieux.Environment` would be less code here and one more contract every
  # embedder has to reproduce; a glob is a composition of listings.
  defp matches(ref, reader) do
    {paths, _budget} =
      ref.path
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))
      |> walk(reader, "", reader.max_glob_dirs)

    Enum.sort(paths)
  end

  defp walk(_segments, _reader, _prefix, budget) when budget <= 0, do: {[], 0}

  # `@lib/**` means every file under `lib`, which is `@lib/**/*` with the last
  # segment left off.
  defp walk(["**"], reader, prefix, budget), do: walk(["**", "*"], reader, prefix, budget)

  defp walk(["**" | rest], reader, prefix, budget) do
    {here, budget} = walk(rest, reader, prefix, budget)

    {deeper, budget} =
      each_directory(reader, prefix, budget, &walk(["**" | rest], reader, &1, &2))

    {here ++ deeper, budget}
  end

  # The last segment is always resolved against a listing, even when it is a
  # literal. Joining it on unchecked would report a match for every directory
  # the walk passed through, and `@lib/**/turn.ex` would then apologise once
  # per directory that has no `turn.ex` in it.
  defp walk([segment], reader, prefix, budget) do
    pattern = pattern(segment)
    {entries, budget} = listed(reader, prefix, budget)

    paths =
      entries
      |> Enum.filter(&(&1.type == :file and Regex.match?(pattern, &1.name)))
      |> Enum.map(&joined(prefix, &1.name))

    {paths, budget}
  end

  defp walk([segment | rest], reader, prefix, budget) do
    if String.contains?(segment, "*") do
      pattern = pattern(segment)

      each_directory(
        reader,
        prefix,
        budget,
        &walk(rest, reader, &1, &2),
        &Regex.match?(pattern, &1)
      )
    else
      walk(rest, reader, joined(prefix, segment), budget)
    end
  end

  # Directories only, which is also what keeps a walk finite: `list_dir/3`
  # reports a symlink as a symlink rather than following it, so a link back up
  # the tree is never descended into.
  defp each_directory(reader, prefix, budget, descend, matching \\ fn _name -> true end) do
    {entries, budget} = listed(reader, prefix, budget)

    entries
    |> Enum.filter(&(&1.type == :directory and matching.(&1.name)))
    |> Enum.flat_map_reduce(budget, &descend.(joined(prefix, &1.name), &2))
  end

  # `Path.join/2` would turn a root-relative walk into an absolute-looking
  # path the moment the prefix is empty, and the environment confines relative
  # paths.
  defp joined("", name), do: name
  defp joined(prefix, name), do: prefix <> "/" <> name

  defp listed(reader, prefix, budget) do
    case Environment.list_dir(reader.environment, reader.cwd, prefix) do
      {:ok, entries} -> {entries, budget - 1}
      {:error, _reason} -> {[], budget - 1}
    end
  end

  # `*` stops at a separator, which is what makes `**` mean something
  # different. Everything else in the segment is matched literally, so a name
  # with a dot or a plus in it is not quietly a pattern.
  defp pattern(segment) do
    source = segment |> String.split("*") |> Enum.map_join("[^/]*", &Regex.escape/1)

    Regex.compile!("^" <> source <> "$")
  end

  # Decided from the name before anything is read: whether a file rides as
  # text or as its own bytes changes which allowance it spends, and reading a
  # four-megabyte PNG to find that out is the thing the allowance exists to
  # prevent.
  defp spend_one(ref, reader, left) do
    case Map.get(@media_types, ref.path |> Path.extname() |> String.downcase()) do
      nil -> spend_text(ref, reader, left)
      media_type -> spend_bytes(ref, reader, left, media_type)
    end
  end

  defp spend_text(ref, _reader, %{bytes: bytes} = left) when bytes <= 0,
    do: {refused(ref, "the prompt's attachment budget was already spent"), left}

  defp spend_text(ref, reader, left) do
    case attach(ref, reader, min(reader.max_bytes, left.bytes)) do
      [] -> {[], left}
      [attachment] -> {[attachment], %{left | bytes: left.bytes - attachment["bytes"]}}
    end
  end

  defp spend_bytes(ref, reader, %{images: 0} = left, _media_type),
    do:
      {refused(ref, "no more than #{reader.max_images} files may ride as their own bytes"), left}

  defp spend_bytes(ref, reader, left, media_type) do
    case bytes(ref, reader, media_type) do
      [] -> {[], left}
      [attachment] -> {[attachment], %{left | images: left.images - 1}}
    end
  end

  defp bytes(ref, reader, media_type) do
    case Environment.read_file(reader.environment, reader.cwd, ref.path) do
      {:ok, contents} when byte_size(contents) > reader.max_image_bytes ->
        refused(ref, "is too large to send, at #{byte_size(contents)} bytes")

      {:ok, contents} ->
        [encoded(ref, contents, media_type)]

      {:error, reason} ->
        refused(ref, unreadable(reason))
    end
  end

  # Base64 because `Lemieux.Entry` requires a JSON-shaped payload and raw
  # bytes are not one. The provider seam decodes it again, because every
  # provider encoder in `req_llm` does its own base64.
  defp encoded(ref, contents, media_type) do
    data = Base.encode64(contents)

    %{
      "ref" => ref.raw,
      "path" => ref.path,
      "kind" => binary_kind(media_type),
      "media_type" => media_type,
      "data" => data,
      "bytes" => byte_size(data)
    }
  end

  defp binary_kind("image/" <> _subtype), do: "image"
  defp binary_kind(_media_type), do: "document"

  defp attach(ref, reader, limit) do
    case Environment.read_file(reader.environment, reader.cwd, ref.path) do
      {:ok, contents} -> [attachment(ref, "file", body(ref.path, contents, limit))]
      {:error, :eisdir} -> directory(ref, reader, limit)
      {:error, reason} -> refused(ref, unreadable(reason))
    end
  end

  # The other half of the ambiguity rule, and the half with teeth: `@test` in
  # a pasted snippet resolving to a directory would attach this repository's
  # whole test tree. A directory has to be asked for — `@test/` or `@./test`.
  defp directory(%__MODULE__{explicit?: false}, _reader, _limit), do: []

  defp directory(ref, reader, limit) do
    case Environment.list_dir(reader.environment, reader.cwd, ref.path) do
      {:ok, entries} -> [attachment(ref, "directory", listing(ref, entries, reader, limit))]
      {:error, reason} -> refused(ref, unreadable(reason))
    end
  end

  defp listing(ref, [], _reader, _limit),
    do: "<attachment path=\"#{ref.path}\" note=\"is an empty directory\" />"

  defp listing(ref, entries, reader, limit) do
    # `kind` is stated when the content is not what an attachment usually is.
    # A numbered listing and a numbered file look alike, and a model that took
    # one for the other would cite line numbers at a directory.
    head = ~s(<attachment path="#{ref.path}" kind="directory">\n)

    body =
      entries
      |> Enum.take(reader.max_entries)
      |> Enum.map(&entry_name/1)
      |> Tool.number_lines(1)
      |> Tool.truncate(limit)

    head <> body <> windowed(length(entries), reader.max_entries) <> "\n</attachment>"
  end

  # The same decoration `Lemieux.Tools.Read` puts on a listing, for the same
  # reason it is shared with the line numbering: one convention, so a model
  # that learned it from a tool result reads an attachment the same way.
  defp entry_name(%{name: name, type: :directory}), do: name <> "/"
  defp entry_name(%{name: name, type: :symlink}), do: name <> "@"
  defp entry_name(%{name: name}), do: name

  defp windowed(total, shown) when total <= shown, do: ""
  defp windowed(total, shown), do: "\n\n[showing #{shown} of #{total} entries]"

  # An ambiguous reference that did not resolve was probably never a reference.
  defp refused(%__MODULE__{explicit?: false}, _reason), do: []

  defp refused(%__MODULE__{} = ref, reason),
    do: [attachment(ref, "error", ~s(<attachment path="#{ref.path}" error="#{reason}" />))]

  defp attachment(ref, kind, text) do
    with_resource(
      %{
        "ref" => ref.raw,
        "path" => ref.path,
        "kind" => kind,
        "text" => text,
        "bytes" => byte_size(text)
      },
      ref
    )
  end

  # The server and URI are kept beside the text, refused ones included, so
  # `from_attachment/1` can read the resource again rather than mistaking
  # `server:uri` for a file.
  defp with_resource(attachment, %__MODULE__{kind: :resource, server: server, uri: uri}),
    do: Map.merge(attachment, %{"server" => server, "uri" => uri})

  defp with_resource(attachment, _ref), do: attachment

  # A plain string rather than `~s(...)`: the wording contains a bracket, and a
  # parenthesised sigil ends at the first one of those.
  defp body(path, "", _limit),
    do: "<attachment path=\"#{path}\" note=\"is empty (0 bytes)\" />"

  defp body(path, contents, limit) do
    numbered =
      contents
      |> Tool.sanitize()
      |> Tool.split_lines()
      |> Tool.number_lines(1)
      |> Tool.truncate(limit)

    ~s(<attachment path="#{path}">\n) <> numbered <> "\n</attachment>"
  end

  @doc """
  Renders `path` as a reference somebody could have typed.

  Quotes it when it has to be quoted. A front end offering completions has to
  produce what `parse/1` will accept: a picker that dropped `report(final).md`
  onto the line unquoted would leave a reference the session reads as
  `report`, and the person would be told that `report` does not exist.

      iex> Lemieux.Reference.render("lib/turn.ex")
      "@lib/turn.ex"

      iex> Lemieux.Reference.render("notes/last final.md")
      ~s(@"notes/last final.md")
  """
  @spec render(path :: String.t()) :: String.t()
  def render(path) when is_binary(path) do
    if Regex.match?(@unquoted, path), do: "@" <> path, else: ~s(@") <> path <> ~s(")
  end

  @doc """
  Renders an MCP resource as a reference somebody could have typed, or `nil`
  when `parse/1` would not read it back as the same resource.

  A resource has no quoted form, so a server name outside letters, digits,
  `_`, `.` and `-`, or a URI with a space or a quote in it, cannot be offered:
  a picker must only put on the line what the session will resolve to the
  thing that was picked.

      iex> Lemieux.Reference.render_resource("docs", "file:///guide.md")
      "@docs:file:///guide.md"

      iex> Lemieux.Reference.render_resource("docs", "file:///my guide.md")
      nil
  """
  @spec render_resource(server :: String.t(), uri :: String.t()) :: String.t() | nil
  def render_resource(server, uri) when is_binary(server) and is_binary(uri) do
    text = "@" <> server <> ":" <> uri

    case parse(text) do
      [%__MODULE__{kind: :resource, server: ^server, uri: ^uri}] -> text
      _not_the_same -> nil
    end
  end

  @doc """
  The reference a stored attachment came from, so it can be read again.

  A session re-reads what a conversation attached from the transcript rather
  than by re-parsing its prompts; see `Lemieux.Session.refresh/1`.
  An attachment is always explicit here, because somebody asked for it once.
  """
  @spec from_attachment(attachment :: attachment()) :: t()
  def from_attachment(%{"server" => server, "uri" => uri} = attachment)
      when is_binary(server) and is_binary(uri) do
    %__MODULE__{
      raw: attachment["ref"],
      path: attachment["path"],
      quoted?: false,
      explicit?: true,
      kind: :resource,
      server: server,
      uri: uri
    }
  end

  def from_attachment(attachment),
    do: %__MODULE__{
      raw: attachment["ref"],
      path: attachment["path"],
      quoted?: false,
      explicit?: true
    }

  @doc """
  Rewrites a payload so a byte-counting estimator does not price an image as
  though it were prose.

  `Lemieux.Request.estimated_tokens/1` and the cost guard in the `req_llm`
  provider both weigh a request by encoding it and counting bytes, on the
  documented ground that one token per byte is pessimistic for text. It is not
  pessimistic for base64: a one-megabyte screenshot reads as a million tokens,
  which is over every budget and every rate limit there is. The session then
  refuses to send a request it could comfortably afford, and the failure looks
  like a stuck agent rather than like a bad estimate.

  So attachment bytes are swapped for a stand-in of the length those bytes
  will actually cost. It is a flat figure because the real one is a function
  of the image's pixel dimensions, and finding those means decoding it.
  """
  @spec estimable(payload :: map()) :: map()
  def estimable(%{"attachments" => [_ | _] = attachments} = payload),
    do: Map.put(payload, "attachments", Enum.map(attachments, &lightened/1))

  def estimable(payload), do: payload

  defp lightened(%{"data" => data} = attachment) when is_binary(data),
    do: Map.put(attachment, "data", String.duplicate("*", @image_tokens))

  defp lightened(attachment), do: attachment

  defp unreadable(:enoent), do: "no such file"
  defp unreadable(:eisdir), do: "is a directory"
  defp unreadable(:outside_worktree), do: "is outside the working directory"
  defp unreadable(:invalid_path), do: "is not a usable path"
  defp unreadable(:unsupported), do: "cannot be read here"
  defp unreadable(reason), do: reason |> :file.format_error() |> List.to_string()
end
