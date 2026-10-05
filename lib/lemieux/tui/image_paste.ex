defmodule Lemieux.TUI.ImagePaste do
  @moduledoc """
  Ctrl-V: the image on the clipboard, as PNG bytes.

  A terminal's paste is text. A screenshot copied to the clipboard reaches a
  terminal program as nothing at all — or, in some terminals, as an empty
  bracketed paste — so reading an image takes asking the operating system,
  which is what this does, with the tool each platform ships:

    * macOS: `osascript`, reading the clipboard as `«class PNGf»` into a
      temporary file;
    * Wayland: `wl-paste --type image/png`;
    * X11: `xclip -selection clipboard -t image/png -o`;
    * Windows: PowerShell's `System.Windows.Forms.Clipboard`.

  The caller decides where the bytes go. `Lemieux.TUI` writes them under the
  session's working directory and puts an `@path` reference in the input
  box, because a reference is how a prompt carries an image to the session
  — through `Lemieux.Reference`, confined to the working directory like
  every other attachment.
  """

  # `Lemieux.Reference` refuses larger images, and an image it would refuse
  # is better refused here, before a file is written for it.
  @max_bytes 3_500_000

  @doc """
  Reads the clipboard's image, or says why there is none.

  `:os` and `:env` replace what is detected, and `:runner` replaces the
  command call; tests use them to reach each platform's branch.
  """
  @spec capture(opts :: keyword()) :: {:ok, binary()} | {:error, String.t()}
  def capture(opts \\ []) do
    os = Keyword.get_lazy(opts, :os, &:os.type/0)
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)
    runner = Keyword.get(opts, :runner, &System.cmd/3)

    with {:ok, bytes} <- read(os, env, runner) do
      checked(bytes)
    end
  end

  defp read({:unix, :darwin}, _env, runner) do
    path = Path.join(System.tmp_dir!(), "lmx-clipboard-#{System.unique_integer([:positive])}.png")

    script = [
      "set f to (POSIX file \"#{path}\")",
      "try",
      "set d to (the clipboard as «class PNGf»)",
      "on error",
      "return \"none\"",
      "end try",
      "set fh to open for access f with write permission",
      "set eof fh to 0",
      "write d to fh",
      "close access fh",
      "return \"ok\""
    ]

    try do
      case runner.("osascript", Enum.flat_map(script, &["-e", &1]), stderr_to_stdout: true) do
        {"ok" <> _rest, 0} ->
          File.read(path) |> file_result()

        {"none" <> _rest, 0} ->
          {:error, "there is no image on the clipboard"}

        {output, _status} ->
          {:error, "osascript could not read the clipboard: #{String.trim(output)}"}
      end
    after
      File.rm(path)
    end
  end

  defp read({:unix, _name}, env, runner) do
    cond do
      present?(env, "WAYLAND_DISPLAY") and System.find_executable("wl-paste") ->
        piped(runner, "wl-paste", ["--no-newline", "--type", "image/png"])

      present?(env, "DISPLAY") and System.find_executable("xclip") ->
        piped(runner, "xclip", ["-selection", "clipboard", "-t", "image/png", "-o"])

      true ->
        {:error, "reading an image needs wl-paste (Wayland) or xclip (X11)"}
    end
  end

  defp read({:win32, _name}, _env, runner) do
    path = Path.join(System.tmp_dir!(), "lmx-clipboard-#{System.unique_integer([:positive])}.png")

    command =
      "Add-Type -AssemblyName System.Windows.Forms; " <>
        "$i = [Windows.Forms.Clipboard]::GetImage(); " <>
        "if ($i) { $i.Save('#{path}', [System.Drawing.Imaging.ImageFormat]::Png); 'ok' } else { 'none' }"

    try do
      case runner.("powershell", ["-NoProfile", "-Command", command], stderr_to_stdout: true) do
        {"ok" <> _rest, 0} -> File.read(path) |> file_result()
        {_output, _status} -> {:error, "there is no image on the clipboard"}
      end
    after
      File.rm(path)
    end
  end

  defp piped(runner, executable, args) do
    case runner.(executable, args, []) do
      {bytes, 0} when byte_size(bytes) > 0 -> {:ok, bytes}
      {_output, _status} -> {:error, "there is no image on the clipboard"}
    end
  end

  defp file_result({:ok, bytes}), do: {:ok, bytes}
  defp file_result({:error, _reason}), do: {:error, "there is no image on the clipboard"}

  defp checked(bytes) when byte_size(bytes) > @max_bytes,
    do:
      {:error,
       "the clipboard image is #{div(byte_size(bytes), 1_000_000)} MB; the limit is 3.5 MB"}

  # A PNG's first eight bytes are its signature. Anything else is a clipboard
  # the tool described as an image and was not one.
  defp checked(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>> = bytes), do: {:ok, bytes}
  defp checked(_bytes), do: {:error, "the clipboard did not hold a PNG image"}

  defp present?(env, name), do: Map.get(env, name, "") != ""
end
