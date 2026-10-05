defmodule Lemieux.Extensions.Hooks do
  @moduledoc """
  Command hooks from a file or a configuration object, appended to the harness.

  `lmx --hooks FILE` is the CLI form; a `"hooks"` object in a person's own
  configuration is the other. Either is read once, at `init/1`, by
  `Lemieux.Hooks.Config.load/2`; a source that cannot be read or parsed stops
  assembly with its message rather than starting a session that runs none of
  the hooks somebody named. The hooks go **after** whatever the host already
  set, for the reason `Lemieux.Harness.append_hooks/2` gives.

  A Claude Code settings file may be named directly: it is read in Claude's
  dialect, and whatever in it has no Lemieux equivalent is reported under
  `"warnings"` in `describe/1` rather than failing the file.

  Trust is the host's decision and stays there: nothing here reads a
  repository's `.claude/settings.json`, and a hook file reaches this
  extension only because a person passed its path or wrote the object.

  Options:

    * `:file` — a hooks file, Lemieux's versioned format or a Claude Code
      settings file;
    * `:config` — an already-decoded document or events object, as
      `~/.lmx/config.json` holds it;
    * `:dialect` and `:credentials` — passed to `Lemieux.Hooks.Config.load/2`.

  Exactly one of `:file` and `:config`.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Harness
  alias Lemieux.Hooks.Config

  @type state :: %{
          source: Path.t() | :config,
          hooks: Lemieux.Hooks.t(),
          warnings: [String.t()]
        }

  @impl Lemieux.Extension
  @spec init(opts :: keyword()) :: {:ok, state()} | {:error, String.t()}
  def init(opts) do
    load_opts = Keyword.take(opts, [:dialect, :credentials])

    case {Keyword.fetch(opts, :file), Keyword.fetch(opts, :config)} do
      {{:ok, file}, :error} ->
        with {:ok, loaded} <- Config.load(file, load_opts), do: {:ok, state(file, loaded)}

      {:error, {:ok, config}} when is_map(config) ->
        with {:ok, loaded} <- Config.load(config, load_opts), do: {:ok, state(:config, loaded)}

      _ambiguous ->
        {:error, "Lemieux.Extensions.Hooks needs exactly one of :file and :config"}
    end
  end

  defp state(source, %{hooks: hooks, warnings: warnings}),
    do: %{source: source, hooks: hooks, warnings: warnings}

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, %{hooks: hooks}), do: Harness.append_hooks(harness, hooks)

  @impl Lemieux.Extension
  def describe(%{source: source, hooks: hooks, warnings: warnings}) do
    %{"hooks" => length(hooks)}
    |> put_source(source)
    |> put_warnings(warnings)
  end

  defp put_source(description, :config), do: Map.put(description, "source", "config")
  defp put_source(description, file), do: Map.put(description, "file", file)

  defp put_warnings(description, []), do: description
  defp put_warnings(description, warnings), do: Map.put(description, "warnings", warnings)
end
