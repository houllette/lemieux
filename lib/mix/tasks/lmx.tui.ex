defmodule Mix.Tasks.Lmx.Tui do
  @shortdoc "Runs the lemieux terminal UI"

  @moduledoc """
  Runs the terminal UI from a source checkout.

  This is a development convenience for exercising current source without
  first assembling an OTP release. Run it from `dist/lmx` to include the bundled
  System One compaction extension. In that host it still uses the repository root as
  the workspace. Installed releases open the same TUI with bare `lmx`.

  Arguments are the terminal UI's own:

      mix lmx.tui --model ollama:qwen3.8:27b-mxfp8

  A local Ollama model sees only the window the Ollama server gives it,
  which can be as small as 4,096 tokens, so start the server with a larger
  one (`OLLAMA_CONTEXT_LENGTH=65536 ollama serve`; `mix lmx help models`).
  `--context-window` changes nothing about that window: it is what lmx
  plans compaction against.

  `-C DIR` (or `--cwd DIR`) points the session at another repository, so the
  source checkout's TUI can work anywhere:

      mix lmx.tui -C ../my-project

  Every other command — `run`, `log`, `fork`, `explain`, `help` — is `mix
  lmx`'s (`Mix.Tasks.Lmx`), which takes the installed binary's arguments
  unchanged; this task is `mix lmx tui`.
  """

  use Mix.Task

  alias Mix.Tasks.Lmx

  @requirements ["app.start"]

  @impl Mix.Task
  def run(argv), do: run_with(argv, &Lemieux.CLI.run/2)

  @doc false
  @spec run_with(
          argv :: [String.t()],
          runner :: ([String.t()], keyword() -> :ok | {:error, pos_integer()}),
          configure :: (-> :ok)
        ) :: :ok
  def run_with(argv, runner, configure \\ &Lemieux.CLI.configure/0),
    do: Lmx.run_with(["tui" | argv], runner, configure)
end
