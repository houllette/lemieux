defmodule Mix.Tasks.Lmx.Extension.Build do
  @shortdoc "Writes a directory the installed lmx loads with --extension NAME"

  @moduledoc """
  Builds this Mix project into an extension directory for the installed
  `lmx` binary.

      mix lmx.extension.build
      mix lmx.extension.build --output ./.lmx/extensions/audit
      mix lmx.extension.build --module MyApp.Audit --name audit

  Run it inside a project that depends on `:lemieux` and defines a
  `Lemieux.Extension`. It compiles the project, then copies its `ebin` and
  the `ebin` of every runtime dependency the binary does not already ship
  into `~/.lmx/extensions/APP` (or `$LMX_EXTENSIONS_DIR/APP`, or `--output`),
  with an `extension.json` recording the module and the lemieux, Elixir and
  OTP versions it was built with. `lmx --extension APP` then loads it;
  `"extensions": ["APP"]` in `~/.lmx/config.json` does so every time.

  The manifest also records the extension API version the build was made
  against. The binary loads a build when that API version is its own, its
  OTP major version matches, and the build's Elixir is the same major
  version and no newer than the binary's (see `Lemieux.CLI.Extensions`); a
  Lemieux patch release no longer needs a rebuild. A bundle built before
  this rule still needs the exact versions it recorded, until it is rebuilt. Dependencies with native
  code are refused; see `Lemieux.CLI.Extensions.Build` for the reasoning and
  `docs/extensions.md` for the alternative.

  ## Options

    * `--output DIR` — write here instead of the personal root
    * `--module MOD` — the extension module, when the project defines more
      than one or the one it defines does not declare the behaviour
    * `--name NAME` — the directory and manifest name, defaulting to the app
  """

  use Mix.Task

  alias Lemieux.CLI.Extensions
  alias Lemieux.CLI.Extensions.Build

  @requirements ["compile"]
  @switches [output: :string, module: :string, name: :string]

  @impl Mix.Task
  def run(argv) do
    with {:ok, options} <- options(argv),
         {:ok, %{directory: directory, manifest: manifest}} <-
           Build.build(build_options(options)) do
      Mix.shell().info(next_steps(manifest, directory, program()))
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  @doc """
  How the lines after a build spell the command that loads it: `lmx` where
  an installed binary is on the path (`find` looks, `System.find_executable/1`
  unless a test replaces it), else `mix lmx`, which runs from a Lemieux
  source checkout (`Mix.Tasks.Lmx`). Telling somebody without the binary to
  run `lmx --extension-dir …` named a command they did not have.
  """
  @spec program(find :: (String.t() -> String.t() | nil)) :: String.t()
  def program(find \\ &System.find_executable/1) when is_function(find, 1) do
    if find.("lmx"), do: "lmx", else: "mix lmx"
  end

  @doc "What the task says once `directory` holds the built `manifest`."
  @spec next_steps(manifest :: map(), directory :: Path.t(), program :: String.t()) ::
          String.t()
  def next_steps(manifest, directory, program) do
    where = if program == "lmx", do: "", else: "\n(mix lmx runs from your Lemieux checkout)"

    """
    Built #{manifest["name"]} (#{manifest["module"]}) into #{directory}
    Run it with:  #{program} --extension-dir #{directory}
    By name, when it is under #{Extensions.default_root()}:  #{program} --extension #{manifest["name"]}#{where}\
    """
  end

  @doc "Parses the task's own switches; anything else is named rather than ignored."
  @spec options(argv :: [String.t()]) :: {:ok, keyword()} | {:error, String.t()}
  def options(argv) do
    case OptionParser.parse(argv, strict: @switches) do
      {parsed, [], []} -> {:ok, parsed}
      {_parsed, _rest, [{flag, _value} | _]} -> {:error, "unrecognised option #{flag}"}
      {_parsed, [word | _], []} -> {:error, "unexpected argument #{word}"}
    end
  end

  # The project's own deps join the tree under its name, so the toolchain
  # check sees a top-level `{:rustler, ...}` as well as a transitive one.
  defp build_options(options) do
    config = Mix.Project.config()
    app = Keyword.fetch!(config, :app)
    top_level = config |> Keyword.get(:deps, []) |> Enum.map(&elem(&1, 0))

    Keyword.take(options, [:output, :module, :name]) ++
      [
        app: app,
        lib: Path.join(Mix.Project.build_path(), "lib"),
        deps_tree: Map.put_new(Mix.Project.deps_tree(), app, top_level)
      ]
  end
end
