defmodule Lemieux.Benchmark.Runtime do
  @moduledoc """
  **Experimental.** May change in any 0.x release.
  A runtime that attempts one benchmark task.

  The behaviour is intentionally smaller than an agent adapter. A benchmark
  needs an answer and observations; how a runtime obtains them is its own
  concern. This lets an embedder compare Lemieux with a subscription-funded
  CLI without teaching the core anything about that CLI.

  A runtime may return `{:error, reason, observation}` when an attempt fails
  after producing evidence. The runner retains its usage and transcript while
  recording a failed attempt and skipping the grader. A bare error used to
  discard paid work when the native host deadline expired.
  """

  alias Lemieux.Benchmark.Task

  @typedoc "A named runtime and the options passed to its implementation."
  @type t :: %__MODULE__{name: String.t(), module: module(), options: keyword()}

  @typedoc "JSON-shaped observations from one attempt."
  @type observation :: map()

  @type result :: {:ok, observation()} | {:error, term()} | {:error, term(), observation()}

  @enforce_keys [:name, :module]
  defstruct [:name, :module, options: []]

  @callback run(task :: Task.t(), opts :: keyword()) ::
              result()

  @doc "Builds a named runtime."
  @spec new(name :: String.t(), module :: module(), opts :: keyword()) :: t()
  def new(name, module, opts \\ [])
      when is_binary(name) and name != "" and is_atom(module) and is_list(opts) do
    %__MODULE__{name: name, module: module, options: opts}
  end

  @doc "Runs one task through a runtime."
  @spec run(runtime :: t(), task :: Task.t()) :: result()
  def run(%__MODULE__{module: module, options: opts}, %Task{} = task) do
    module.run(task, opts)
  end
end
