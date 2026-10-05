defmodule Lemieux.TUI.ExternalEditor do
  @moduledoc """
  Ctrl-G: the input box's text in `$VISUAL` or `$EDITOR`, and back.

  A long prompt is easier to write in the editor somebody already knows than
  in a box with a word-wrapped caret. The terminal is the hard part: the
  screen holds it in raw mode on the alternate screen with mouse reporting
  on, and an editor started into that sees none of the keys it expects and
  paints over a buffer it did not draw.

  So the handoff is one shell script, run from inside the screen's own
  process while it waits — which is what stops the screen's input poll from
  racing the editor for keystrokes, since the poll runs in that same process.
  The script saves the terminal's settings with `stty -g`, leaves the
  alternate screen and turns mouse and bracketed-paste reporting off, puts the
  terminal in its ordinary mode, runs the editor on the terminal, and then
  restores exactly the saved settings and modes. It clears the screen last,
  because the screen's renderer only repaints cells it believes changed:
  `Lemieux.TUI` repaints everything on the next two frames (see
  `Lemieux.TUI.Screen`), and a cleared screen is what those frames paint
  over.

  The terminal is named to the script by its device path (`$3`), not as
  `/dev/tty`: the script runs in a session of its own with no controlling
  terminal, where `/dev/tty` names nothing, and every handoff used to fail
  at its first line with "this terminal could not be handed to an editor".
  `Lemieux.TUI.Tty` has the details.

  What the handoff cannot do is make the editor the terminal's foreground
  job: it runs on the terminal's device, but outside the session the
  terminal belongs to, so the signals the terminal raises still go to the
  VM's process group. The script turns the keys that raise them off for the
  edit (`-isig`), so Ctrl-C, Ctrl-Z and Ctrl-\\ are keys the editor reads —
  vim and nano take them that way anyway — rather than an interrupt, a stop
  or a quit for `lmx` behind it; while a window editor (`code --wait`) is
  open they are typed into the waiting terminal, and the screen reads them
  once the editor closes. A resize during the edit is still the VM's to
  hear, so a terminal editor keeps its old size until it redraws.

  The draft is written into a directory made for it alone, mode `0700`,
  and created `:exclusive` there: it is somebody's unsent prompt, and a
  predictable name in a shared temporary directory was one another account
  could create first — as a symlink, which `File.write/2` follows — or read
  before its mode was narrowed.

  `$VISUAL` wins over `$EDITOR`, as in git, and either may carry arguments
  (`code --wait`). With neither set the editor is `vi`, which every system
  this runs on has. Only the local transport gets one: the terminal this
  process is attached to is not the one a remote transport draws on, and
  native Windows has no terminal device to hand over at all, so there
  Ctrl-G says it does not work yet.
  """

  alias Lemieux.Environment.Inherited
  alias Lemieux.TUI.Tty

  @script ~S"""
  tty=$3
  saved=$(stty -g < "$tty") || exit 90
  printf '\033[?1000l\033[?1002l\033[?1003l\033[?1015l\033[?1006l\033[?2004l\033[?25h\033[?1049l' > "$tty"
  stty sane -isig < "$tty"
  $LMX_EDITOR "$1" < "$tty" > "$tty" 2>&1
  status=$?
  stty "$saved" < "$tty"
  printf '\033[?1049h\033[?2004h' > "$tty"
  if [ "$2" = "mouse" ]; then
    printf '\033[?1000h\033[?1002h\033[?1003h\033[?1015h\033[?1006h' > "$tty"
  fi
  printf '\033[?25l\033[2J' > "$tty"
  exit $status
  """

  @doc """
  Opens `text` in the configured editor and returns what was saved.

  `{:error, reason}` when the terminal could not be handed over or the
  editor exited unsuccessfully; the text in the box is left as it was, so a
  crash in the editor never costs a draft.

  Options: `:mouse?` restores mouse reporting afterwards (the screen's own
  setting), `:env` replaces the environment the editor is chosen from,
  `:os` the `:os.type/0` answer, `:sh` the shell that runs the handoff
  (`sh` on `PATH` by default, `nil` for none), `:tty` the terminal device it
  hands over (`Lemieux.TUI.Tty`'s by default, `nil` for none), and `:runner`
  replaces the shell call, which is how a test runs this without a
  terminal; it is given the editor, the draft's path and `mouse?`.
  """
  @spec edit(text :: String.t(), opts :: keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def edit(text, opts \\ []) when is_binary(text) do
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    editor = editor(env)
    os = Keyword.get_lazy(opts, :os, &:os.type/0)
    sh = Keyword.get_lazy(opts, :sh, fn -> System.find_executable("sh") end)
    runner = Keyword.get_lazy(opts, :runner, fn -> handoff(os, sh, opts) end)

    result =
      with {:ok, dir} <- draft_dir() do
        try do
          edited_in(dir, text, fn path ->
            runner.(editor, path, Keyword.get(opts, :mouse?, true))
          end)
        after
          File.rm_rf(dir)
        end
      end

    said(result)
  end

  defp edited_in(dir, text, run) do
    path = Path.join(dir, "lmx-draft.md")

    with :ok <- write_draft(path, text),
         :ok <- run.(path),
         {:ok, edited} <- File.read(path) do
      {:ok, String.replace_suffix(edited, "\n", "")}
    end
  end

  defp said({:error, reason}) when is_atom(reason),
    do: {:error, reason |> :file.format_error() |> to_string()}

  defp said(result), do: result

  # See the moduledoc: `mkdir` fails on anything already at the name, so the
  # directory is this call's own, and its mode is narrowed before the draft
  # exists.
  defp draft_dir do
    name = "lmx-draft-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    dir = Path.join(System.tmp_dir!(), name)

    with :ok <- File.mkdir(dir),
         :ok <- File.chmod(dir, 0o700) do
      {:ok, dir}
    end
  end

  defp write_draft(path, text) do
    with {:ok, file} <- File.open(path, [:write, :exclusive, :binary]) do
      try do
        with :ok <- File.chmod(path, 0o600), do: IO.binwrite(file, text)
      after
        File.close(file)
      end
    end
  end

  @doc "The editor command `edit/2` would run: `$VISUAL`, then `$EDITOR`, then `vi`."
  @spec editor(env :: %{optional(String.t()) => String.t()}) :: String.t()
  def editor(env) do
    Enum.find_value(["VISUAL", "EDITOR"], "vi", &configured(Map.get(env, &1)))
  end

  defp configured(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      editor -> editor
    end
  end

  defp configured(_unset), do: nil

  # Native Windows has no terminal device to name (`Lemieux.TUI.Tty`), so
  # there is nothing to hand over even with Git Bash's `sh` on PATH; saying
  # "needs sh" there sent people to install something that would not help.
  # Elsewhere the handoff is a shell script, and a system without `sh` made
  # `System.cmd/3` raise, which took the screen down with the draft in it. A
  # shell that is found and then cannot be started — removed, or not
  # executable — is the same failure a moment later, so it is caught where
  # the process is spawned and said the same way.
  defp handoff({:win32, _name}, _sh, _opts),
    do: fn _editor, _path, _mouse? -> {:error, windows()} end

  defp handoff(_unix, nil, _opts), do: fn _editor, _path, _mouse? -> {:error, no_shell()} end

  defp handoff(_unix, sh, opts) do
    case terminal(opts) do
      nil -> fn _editor, _path, _mouse? -> {:error, no_terminal()} end
      tty -> &hand_over(sh, tty, &1, &2, &3)
    end
  end

  # Looked up only when nobody said, so a test that says `tty: nil` never
  # opens an editor on the terminal running the suite.
  defp terminal(opts) do
    case Keyword.fetch(opts, :tty) do
      {:ok, tty} -> tty
      :error -> Tty.device()
    end
  end

  defp hand_over(sh, tty, editor, path, mouse?) do
    mode = if mouse?, do: "mouse", else: "plain"

    # The person's own environment, as the host restored it
    # (`Lemieux.Environment.Inherited`): an editor that starts a language
    # server finds the person's `elixir`, not the installed lmx's Erlang.
    case System.cmd(sh, ["-c", @script, "lmx-editor", path, mode, tty],
           env: Inherited.cmd_env() ++ [{"LMX_EDITOR", editor}],
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, 90} -> {:error, no_terminal()}
      {_output, status} -> {:error, "#{editor} exited with status #{status}"}
    end
  rescue
    error in ErlangError -> {:error, not_started(error.original)}
  end

  # Missing or not executable is the missing shell; anything else — out of
  # file descriptors, say — is its own reason, and blaming the shell for it
  # sent people looking for one they already had.
  defp not_started(reason) when reason in [:enoent, :eacces], do: no_shell()

  defp not_started(reason) when is_atom(reason),
    do: "could not start sh to hand the terminal over: #{:file.format_error(reason)}"

  defp not_started(reason), do: "could not start sh to hand the terminal over: #{inspect(reason)}"

  defp no_shell, do: "Ctrl-G needs a POSIX `sh` on PATH to hand the terminal over"

  defp windows,
    do: "Ctrl-G does not work on Windows yet: there is no terminal device to hand an editor"

  defp no_terminal, do: "this terminal could not be handed to an editor"
end
