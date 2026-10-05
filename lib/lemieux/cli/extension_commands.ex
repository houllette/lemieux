defmodule Lemieux.CLI.ExtensionCommands do
  @moduledoc """
  `lmx extension new NAME [--dir D]` and `lmx extension list`.

  `new` writes the smallest extension the loader accepts — a manifest and
  one `.exs` file (`Lemieux.CLI.Extensions.Scaffold`) — under the personal
  extensions root, where `--extension NAME` and the config file's
  `"extensions"` find it. `list` reads the manifests there and says, for
  each, whether this `lmx` would load it, without compiling anything.
  """

  alias Lemieux.CLI.Extensions
  alias Lemieux.CLI.Extensions.Scaffold

  @doc "Runs an `extension` subcommand, printing what it did."
  @spec run(argv :: [String.t()], opts :: keyword()) :: :ok | {:error, pos_integer()}
  def run(argv, opts \\ []) do
    case OptionParser.parse(argv, strict: [dir: :string]) do
      {parsed, ["new", name], []} -> new(name, parsed[:dir], opts)
      {[], ["list"], []} -> list(opts)
      _usage -> fail("usage: lmx extension new NAME [--dir DIR] | lmx extension list")
    end
  end

  defp new(name, dir, opts) do
    root = root(opts)
    directory = if dir, do: Path.expand(dir), else: Path.join(root, name)

    case Scaffold.script(directory, name) do
      {:ok, written} ->
        IO.puts("""
        Wrote #{written.script}.
        Load it with lmx --extension #{name}#{if dir, do: " (after moving it under #{root})", else: ""},
        or add "#{name}" to "extensions" in ~/.lmx/config.json.\
        """)

      {:error, message} ->
        fail(message)
    end
  end

  defp list(opts) do
    case Extensions.list(root: root(opts)) do
      [] ->
        IO.puts("No extensions in #{root(opts)}. lmx extension new NAME writes one.")

      listed ->
        Enum.each(listed, fn extension ->
          IO.puts("#{extension.name} · #{extension.kind} · #{status(extension.status)}")
        end)
    end
  end

  defp status(:ok), do: "loads"
  defp status({:error, reason}), do: "will not load: #{reason}"

  defp root(opts), do: Keyword.get_lazy(opts, :extensions_dir, &Extensions.default_root/0)

  defp fail(message) do
    IO.puts(:stderr, "lmx: #{message}")
    {:error, 1}
  end
end
