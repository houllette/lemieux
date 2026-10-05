defmodule Lemieux.TUI.Links do
  @moduledoc """
  Resolves a click on a visibly linked transcript span to a safe target, and
  opens it safely.

  The terminal reports a cell, not a hyperlink. Model Markdown links are
  rendered as a label with a visible destination, so this module reads the
  visible row at that cell. Only HTTP(S) addresses and existing local files
  are targets; an arbitrary URI scheme in model output must not become a
  local command.

  ## A local file is read, never run

  The path under the pointer is whatever the model wrote, and the file may be
  one it wrote too. Handing it to the operating system's default opener —
  `open`, `explorer.exe`, `xdg-open` — ran it: a `.command` opens a Terminal
  and executes, a `.bat` runs under `explorer.exe`, a `.jar` starts, all
  with the person's full rights and outside the approval mode and the
  sandbox the session ran under, after one click on what looked like a file
  reference. So a local file is opened as text or shown in the file manager,
  and nothing else:

    * a file whose type launches, installs or runs code — an application or
      bundle, an installer, a shortcut or link file, a shell, Windows or
      AppleScript script (`.app`, `.command`, `.sh`, `.exe`, `.bat`, `.ps1`,
      `.scpt`, `.terminal`, `.webloc`, `.desktop`, `.jar`, … — the full list
      is kept beside the code) — is not opened at all, and the screen says
      so;
    * text — judged by the first bytes, not the name — opens in a text
      editor: `open -t` on macOS and Notepad on Windows, whatever the file's
      association. On Linux there is no such command, so `xdg-open` is used
      for text, except for source in a language a desktop may associate
      with its interpreter, a web page, or a script that starts with `#!`,
      which are shown in their folder instead;
    * anything else is shown in its folder: `open -R` in Finder,
      `explorer /select,` on Windows, the folder itself through `xdg-open`.

  A file is judged by every name it goes by: its own, each symlink it
  points through and the file at the end, so `notes.md -> a.md ->
  run.command` is a `.command`. Looking one link deep let a second link hide
  the type.

  HTTP(S) addresses still open in the browser.
  """

  @markdown ~r/\[([^\]\n]+)\]\((<?[^\s)>]+>?)(?:\s+"[^"]*")?\)/
  @display ~r/↗ ([^()\n]+) \(([^()\s]+)\)/
  @address ~r/(?:https?:\/\/|file:\/\/)[^\s<>()\[\]]+/
  @path ~r/(?<![\w:])(?:\.{1,2}\/|~\/|\/|[\w.-]+\/)[\w.\/-]*\.[[:alnum:]_-]+(?::\d+(?::\d+)?)?/

  # Types the operating system launches, installs or runs when a file is
  # opened by its association, on any of the three: applications and
  # bundles, installers and packages, shortcuts and link files, and scripts
  # of the shells and of Windows and macOS themselves.
  @refused ~w(
    .app .bundle .command .tool .terminal .scpt .scptd .applescript .workflow .action
    .webloc .inetloc .fileloc .pkg .mpkg .dmg .prefpane .kext .osax
    .exe .com .bat .cmd .ps1 .psm1 .psd1 .ps1xml .vbs .vbe .jse .wsf .wsh .wsc .msi .msp
    .msc .scr .pif .cpl .hta .lnk .url .reg .inf .appref-ms .application .gadget .scf
    .settingcontent-ms .library-ms .search-ms .xll .appx .msix .appinstaller
    .jar .jnlp .desktop .sh .bash .zsh .ksh .csh .tcsh .fish .run .bin .appimage .deb .rpm
    .snap .flatpakref
  )

  # Text a Linux desktop may hand to something other than an editor: source
  # in languages with interpreters a file manager can run it with, and web
  # pages a browser renders and scripts. Shown in its folder on Linux; macOS
  # and Windows open it in a text editor whatever its association — which is
  # why `.js`, which Windows Script Host runs by association, is not refused
  # outright: clicking `src/index.js` opens it in Notepad there.
  @linux_revealed ~w(.py .pyw .pl .rb .php .lua .tcl .js .mjs .cjs .html .htm .xhtml .svg)

  # Names that are text when the file cannot be read to tell.
  @text_names ~w(.md .markdown .txt .text .log .rst .adoc)

  @doc "Target under a zero-based transcript cell, or nil when it is not openable."
  @spec target_at(
          view :: map(),
          point :: {non_neg_integer(), non_neg_integer()},
          cwd :: String.t() | nil,
          width :: pos_integer() | nil
        ) :: String.t() | nil
  def target_at(view, point, cwd, width \\ nil)

  def target_at(%{rows: rows, bottom: bottom}, {depth, column}, cwd, width) do
    index = length(rows) - 1 - (depth - bottom)

    with true <- index >= 0 and index < length(rows),
         true <- linked_column?(Enum.at(rows, index), column),
         {text, column} <- stitched(rows, index, column, width),
         {_start, _length, target} <- Enum.find(matches(text), &covers?(&1, text, column)) do
      resolve(target, cwd)
    else
      _other -> nil
    end
  end

  defp linked_column?(%{spans: spans}, column) do
    {_position, linked?} =
      Enum.reduce_while(spans, {0, false}, fn span, {position, _linked?} ->
        next = position + String.length(span.content)

        if column < next,
          do: {:halt, {next, :underlined in span.style.modifiers}},
          else: {:cont, {next, false}}
      end)

    linked?
  end

  defp stitched(rows, index, column, width) when is_integer(width) and width > 0 do
    texts = Enum.map(rows, &Enum.map_join(&1.spans, fn span -> span.content end))
    first = first_row(texts, index, width)
    last = last_row(texts, index, width)
    prefix = texts |> Enum.slice(first, index - first) |> Enum.map_join(& &1)
    {texts |> Enum.slice(first, last - first + 1) |> Enum.join(), String.length(prefix) + column}
  end

  defp stitched(rows, index, column, _width) do
    row = Enum.at(rows, index)
    {Enum.map_join(row.spans, & &1.content), column}
  end

  defp first_row(texts, index, width) when index > 0 do
    if String.length(Enum.at(texts, index - 1)) == width,
      do: first_row(texts, index - 1, width),
      else: index
  end

  defp first_row(_texts, index, _width), do: index

  defp last_row(texts, index, width) do
    if index < length(texts) - 1 and String.length(Enum.at(texts, index)) == width,
      do: last_row(texts, index + 1, width),
      else: index
  end

  @doc """
  Opens a resolved HTTP(S) address in the browser, or a local file as text
  or in its folder; refuses a file whose type runs code (see the moduledoc)
  with `{:error, {:refused, why}}`.
  """
  @spec open(target :: String.t()) :: :ok | {:error, term()}
  def open(target) when is_binary(target) do
    case opener_command(target, :os.type()) do
      {:refused, why} -> {:error, {:refused, why}}
      {command, args} -> launch(command, args)
    end
  end

  defp launch(command, args) do
    case System.find_executable(command) do
      nil ->
        {:error, :opener_unavailable}

      executable ->
        case System.cmd(executable, args, stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {_output, status} -> {:error, {:opener_failed, status}}
        end
    end
  end

  @doc """
  How `open/1` opens `target` on `os`: the program and its arguments, or
  `{:refused, why}` for a local file whose type launches or runs code.

  An HTTP(S) address goes to the platform's opener. A local file is judged
  by its name for the refusal and by its first bytes for whether it is text
  (by its name when it cannot be read); see the moduledoc for where each
  kind goes.
  """
  @spec opener_command(target :: String.t(), os :: tuple()) ::
          {String.t(), [String.t()]} | {:refused, String.t()}
  def opener_command(target, os) do
    if web?(target),
      do: browser(target, os),
      else: local(target, kind(target), os)
  end

  defp web?(target), do: URI.parse(target).scheme in ["http", "https"]

  defp browser(target, {:unix, :darwin}), do: {"open", [target]}
  defp browser(target, {:win32, _name}), do: {"explorer.exe", [target]}
  defp browser(target, _os), do: {"xdg-open", [target]}

  defp local(_path, {:refused, extension}, _os) do
    {:refused,
     "#{extension} files can run code, so lmx does not open them; open it yourself if you meant to"}
  end

  defp local(path, {:text, _how}, {:unix, :darwin}), do: {"open", ["-t", path]}
  defp local(path, :other, {:unix, :darwin}), do: {"open", ["-R", path]}
  defp local(path, {:text, _how}, {:win32, _name}), do: {"notepad.exe", [windows(path)]}
  defp local(path, :other, {:win32, _name}), do: {"explorer.exe", ["/select," <> windows(path)]}
  defp local(path, {:text, :plain}, _linux), do: {"xdg-open", [path]}
  defp local(path, {:text, :runnable}, os), do: local(path, :other, os)
  defp local(path, :other, _os), do: {"xdg-open", [Path.dirname(path)]}

  defp windows(path), do: String.replace(path, "/", "\\")

  defp kind(path) do
    extensions = path |> names() |> Enum.map(&extension/1) |> Enum.uniq()

    case Enum.find(extensions, &(&1 in @refused)) do
      nil -> contents(path, extensions)
      extension -> {:refused, extension}
    end
  end

  # The path, then each link's target in turn, to the file at the end —
  # joined to the link's directory without collapsing `..`, which the
  # kernel resolves from where the link really is — bounded so a loop ends.
  defp names(path, hops \\ 0) do
    case File.read_link(path) do
      {:ok, target} when hops < 40 ->
        [path | names(Path.absname(target, Path.dirname(path)), hops + 1)]

      _not_a_link ->
        [path]
    end
  end

  defp extension(path), do: path |> Path.extname() |> String.downcase()

  # Text is no NUL byte and valid UTF-8 — a multi-byte character cut by the
  # read still counts — in the first 8 KiB; a file that cannot be read is
  # text only if its name says so. Text a Linux desktop may run rather than
  # show is `:runnable`: a `#!` script, or a name in `@linux_revealed`.
  defp contents(path, extensions) do
    runnable? = Enum.any?(extensions, &(&1 in @linux_revealed))

    case head(path) do
      {:ok, "#!" <> _script} -> {:text, :runnable}
      {:ok, bytes} -> if text_bytes?(bytes), do: {:text, text_kind(runnable?)}, else: :other
      :unreadable -> if extension(path) in @text_names, do: {:text, :plain}, else: :other
    end
  end

  defp text_kind(true), do: :runnable
  defp text_kind(false), do: :plain

  defp head(path) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        try do
          case IO.binread(file, 8_192) do
            :eof -> {:ok, ""}
            bytes when is_binary(bytes) -> {:ok, bytes}
            _error -> :unreadable
          end
        after
          File.close(file)
        end

      {:error, _reason} ->
        :unreadable
    end
  end

  defp text_bytes?(bytes), do: not String.contains?(bytes, <<0>>) and utf8?(bytes)

  defp utf8?(bytes) do
    case :unicode.characters_to_binary(bytes) do
      converted when is_binary(converted) -> true
      {:incomplete, _converted, _rest} -> true
      {:error, _converted, _rest} -> false
    end
  end

  defp matches(text) do
    displayed =
      for [{start, length}, _label, {target_start, target_length}] <-
            Regex.scan(@display, text, return: :index) do
        {start, length, binary_part(text, target_start, target_length)}
      end

    markdown =
      for [{start, length}, _label, {target_start, target_length}] <-
            Regex.scan(@markdown, text, return: :index) do
        {start, length, binary_part(text, target_start, target_length) |> String.trim("<>")}
      end

    plain =
      for [{start, length}] <- Regex.scan(@address, text, return: :index) do
        candidate = binary_part(text, start, length) |> String.replace(~r/[.,;:!?]+$/, "")
        {start, byte_size(candidate), candidate}
      end

    paths =
      for [{start, length}] <- Regex.scan(@path, text, return: :index) do
        candidate = binary_part(text, start, length) |> String.replace(~r/[.,;:!?]+$/, "")
        {start, byte_size(candidate), candidate}
      end

    displayed ++ markdown ++ plain ++ paths
  end

  defp covers?({start, length, _target}, text, column) do
    first = text |> binary_part(0, start) |> String.length()
    last = text |> binary_part(0, start + length) |> String.length()
    column >= first and column < last
  end

  defp resolve("https://" <> _rest = url, _cwd), do: web_url(url)
  defp resolve("http://" <> _rest = url, _cwd), do: web_url(url)

  defp resolve("file://" <> _rest = url, cwd) do
    uri = URI.parse(url)
    if uri.host in [nil, "", "localhost"], do: resolve(URI.decode(uri.path || ""), cwd)
  end

  defp resolve(path, cwd) do
    if is_nil(URI.parse(path).scheme) do
      path = Regex.replace(~r/:\d+(?::\d+)?$/, path, "")
      root = cwd || File.cwd!()
      expanded = Path.expand(path, root)
      if File.regular?(expanded), do: expanded
    end
  end

  defp web_url(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> url
      _other -> nil
    end
  end
end
