defmodule HelloExtension do
  @moduledoc "A small extension that adds a deterministic word-count tool."
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  @impl true
  @spec init(opts :: keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def init(opts) do
    # A Mix host passes keyword options; the CLI loader passes JSON as :config.
    note =
      Keyword.get(
        opts,
        :note,
        Keyword.get(opts, :config, %{})["note"] || "Count words with word_count."
      )

    if is_binary(note) and String.trim(note) != "",
      do: {:ok, note},
      else: {:error, "note must be non-empty text"}
  end

  @impl true
  @spec apply(harness :: Lemieux.Harness.t(), note :: String.t()) :: Lemieux.Harness.t()
  def apply(harness, note) do
    harness
    |> Lemieux.Harness.update_system(fn system ->
      Enum.join(Enum.reject([system, note], &is_nil/1), "\n\n")
    end)
    |> Lemieux.Harness.update_tools(&(&1 ++ [HelloExtension.WordCount]))
  end

  @impl true
  @spec describe(note :: String.t()) :: map()
  def describe(_note), do: %{"tool" => "word_count", "revision" => 1}
end

defmodule HelloExtension.WordCount do
  @moduledoc "Counts whitespace-separated words without filesystem or network access."
  @behaviour Lemieux.Tool

  @impl true
  @spec name() :: String.t()
  def name, do: "word_count"
  @impl true
  @spec description() :: String.t()
  def description, do: "Count whitespace-separated words in text."
  @impl true
  @spec schema() :: map()
  def schema,
    do: %{
      "type" => "object",
      "properties" => %{"text" => %{"type" => "string"}},
      "required" => ["text"]
    }

  @impl true
  @spec run(args :: map(), context :: Lemieux.Tool.context()) ::
          {:ok, String.t()} | {:error, String.t()}
  def run(%{"text" => text}, _context) when is_binary(text),
    do: {:ok, "#{length(String.split(text))} words"}

  def run(_args, _context), do: {:error, "text must be a string"}
  @impl true
  @spec read_only?() :: boolean()
  def read_only?, do: true
  @impl true
  @spec parallel_safe?() :: boolean()
  def parallel_safe?, do: true
end
