if Code.ensure_loaded?(ExRatatui.App) do
  defmodule Lemieux.TUI.ImageAttachment do
    @moduledoc """
    Ctrl-V's second half: an image off the clipboard, attached to the prompt.

    `Lemieux.TUI.ImagePaste` reads the bytes; this writes them where the
    session can read them back and puts a reference in the input box. Where
    is `.lmx/pastes/` under the session's working directory, through the
    session's environment: a reference resolves only inside the working
    directory (`Lemieux.Reference`), and a file written beside the session
    rather than in `/tmp` is one the session is allowed to read. The
    directory gets a `.gitignore` of `*` on first use, so a pasted screenshot
    never turns up in `git status`.

    Both happen in a task — reading the clipboard runs a process — and the
    reference arrives as `{:image_pasted, result}`.
    """

    alias Lemieux.Environment
    alias Lemieux.TUI
    alias Lemieux.TUI.Composer
    alias Lemieux.TUI.Flash

    @directory ".lmx/pastes"

    @doc false
    @spec request(TUI.t()) :: TUI.t()
    def request(%TUI{terminal: %{paste_image: nil}} = state),
      do: Flash.show(state, "pasting an image needs a local terminal")

    def request(%TUI{references: %{cwd: nil}} = state),
      do: Flash.show(state, "no working directory to put the image in yet")

    def request(state) do
      app = self()
      capture = state.terminal.paste_image
      environment = state.references.environment || Environment.local()
      cwd = state.references.cwd

      Task.start(fn -> send(app, {:image_pasted, attach(capture, environment, cwd)}) end)
      Flash.show(state, "reading the clipboard…")
    end

    @doc false
    @spec pasted(TUI.t(), {:ok, String.t()} | {:error, String.t()}) :: TUI.t()
    def pasted(state, {:ok, path}) do
      :ok = ExRatatui.textarea_insert_str(state.input, "@#{path} ")
      state |> Composer.edited() |> Flash.show("image attached as @#{path}")
    end

    def pasted(state, {:error, reason}), do: Flash.show(state, reason)

    @doc false
    @spec attach((-> {:ok, binary()} | {:error, String.t()}), Environment.t(), Path.t()) ::
            {:ok, String.t()} | {:error, String.t()}
    def attach(capture, environment, cwd) do
      name = "#{@directory}/paste-#{System.os_time(:millisecond)}.png"

      with {:ok, bytes} <- capture.(),
           :ok <- ignored(environment, cwd),
           {:ok, _disposition} <- Environment.write_file(environment, cwd, name, bytes) do
        {:ok, name}
      else
        {:error, reason} when is_binary(reason) -> {:error, reason}
        {:error, reason} -> {:error, "could not save the image: #{inspect(reason)}"}
      end
    end

    defp ignored(environment, cwd) do
      path = @directory <> "/.gitignore"

      case Environment.read_file(environment, cwd, path) do
        {:ok, _contents} ->
          :ok

        {:error, _missing} ->
          case Environment.write_file(environment, cwd, path, "*\n") do
            {:ok, _disposition} -> :ok
            {:error, _reason} = error -> error
          end
      end
    end
  end
end
