defmodule Lemieux.Subagent.Group.Result do
  @moduledoc "The ordered, all-settled result of one delegated fan-out."

  alias Lemieux.Subagent.Result
  alias Lemieux.Tool
  alias Lemieux.Usage

  @type status :: :ok | :partial | :failed | :cancelled | :timeout
  @type t :: %__MODULE__{
          group_id: String.t(),
          parent_id: String.t(),
          status: status(),
          results: [Result.t()],
          usage: map()
        }

  @enforce_keys [:group_id, :parent_id, :status, :results, :usage]
  defstruct [:group_id, :parent_id, :status, :results, :usage]

  @doc "Builds an aggregate without discarding failed siblings or input ordering."
  @spec new(group_id :: String.t(), parent_id :: String.t(), results :: [Result.t()]) :: t()
  def new(group_id, parent_id, results) when is_list(results) do
    %__MODULE__{
      group_id: group_id,
      parent_id: parent_id,
      status: status(results),
      results: results,
      usage: usage(results)
    }
  end

  @doc "Converts an aggregate to a durable JSON-shaped payload."
  @spec to_map(result :: t()) :: map()
  def to_map(%__MODULE__{} = result) do
    %{
      "group_id" => result.group_id,
      "parent_id" => result.parent_id,
      "status" => Atom.to_string(result.status),
      "results" => Enum.map(result.results, &Result.to_map/1),
      "usage" => result.usage
    }
  end

  @doc "Reconstructs a persisted all-settled aggregate."
  @spec from_map(map()) :: {:ok, t()} | {:error, term()}
  def from_map(%{
        "group_id" => group_id,
        "parent_id" => parent_id,
        "status" => status,
        "results" => results,
        "usage" => usage
      })
      when is_list(results) and is_map(usage) do
    with {:ok, status} <- persisted_status(status),
         {:ok, results} <- persisted_results(results) do
      {:ok,
       %__MODULE__{
         group_id: group_id,
         parent_id: parent_id,
         status: status,
         results: results,
         usage: usage
       }}
    end
  end

  def from_map(_map), do: {:error, :invalid_persisted_group_result}

  # Where the answer text is when the rendering is over budget: the whole
  # budget's worth of children with a short envelope each is well under a
  # kilobyte, so nearly all of it is answers, and it is answers that give.
  @default_budget 120_000
  @clip_note " … [clipped by lemieux; the full answer is in the child's transcript]"

  @doc """
  Renders the one bounded tool result inserted into the parent model context.

  Fits `max_bytes` by shortening the longest answers first, each with a note
  saying so, and never by cutting the JSON. The renderer used to cut the
  encoded document down the middle — in one session on 2026-09-18 three
  answers came back as one blob with 6 KB missing from the second child and
  a note where the JSON should have closed. The parent model coped, which is
  the only reason it was noticed. What is cut is now visible in the
  envelope, and what remains is always a document.
  """
  @spec render(result :: t(), max_bytes :: pos_integer()) :: String.t()
  def render(%__MODULE__{} = result, max_bytes \\ @default_budget) do
    encoded = result |> to_map() |> JSON.encode!()

    if byte_size(encoded) <= max_bytes,
      do: encoded,
      else:
        result
        |> fit(max_bytes, byte_size(encoded) - max_bytes)
        |> to_map()
        |> JSON.encode!()
        |> Tool.truncate(max_bytes)
  end

  # Takes `excess` bytes out of the answers, longest first, so a short
  # answer beside a long one is never the one that loses words.
  defp fit(result, _max_bytes, excess) do
    answers =
      result.results
      |> Enum.with_index()
      |> Enum.map(fn {r, i} -> {i, byte_size(r.answer || "")} end)

    budgets = shrink(Map.new(answers), excess + byte_size(@clip_note) * length(answers))

    results =
      result.results
      |> Enum.with_index()
      |> Enum.map(fn {child, index} -> clip_answer(child, Map.fetch!(budgets, index)) end)

    %{result | results: results}
  end

  # Water-filling in reverse: level the longest answers down together until
  # the excess is paid, so the shortest keep their length.
  defp shrink(sizes, excess) when excess <= 0, do: sizes

  defp shrink(sizes, excess) do
    longest = sizes |> Map.values() |> Enum.max()
    at_top = sizes |> Enum.filter(fn {_i, size} -> size == longest end) |> Enum.map(&elem(&1, 0))
    next = sizes |> Map.values() |> Enum.reject(&(&1 == longest)) |> Enum.max(fn -> 0 end)
    per_answer = min(longest - next, div(excess + length(at_top) - 1, length(at_top)))
    per_answer = max(per_answer, 1)

    sizes =
      Enum.reduce(at_top, sizes, fn i, acc -> Map.update!(acc, i, &max(&1 - per_answer, 0)) end)

    shrink(sizes, excess - per_answer * length(at_top))
  end

  defp clip_answer(%Result{answer: answer} = child, _budget) when not is_binary(answer), do: child

  defp clip_answer(%Result{answer: answer} = child, budget) when byte_size(answer) <= budget,
    do: child

  defp clip_answer(%Result{answer: answer} = child, budget) do
    kept =
      answer
      |> binary_part(0, budget)
      |> then(&if(String.valid?(&1), do: &1, else: String.replace_invalid(&1)))

    %{
      child
      | answer: kept <> @clip_note,
        uncertainties:
          child.uncertainties ++
            [
              "#{byte_size(answer) - budget} bytes of the answer were clipped to fit the parent's tool result"
            ]
    }
  end

  defp status([]), do: :failed

  defp status(results) do
    statuses = Enum.map(results, & &1.status)

    cond do
      Enum.all?(statuses, &(&1 == :ok)) -> :ok
      Enum.all?(statuses, &(&1 == :cancelled)) -> :cancelled
      Enum.all?(statuses, &(&1 == :timeout)) -> :timeout
      Enum.any?(statuses, &(&1 == :ok)) -> :partial
      true -> :failed
    end
  end

  defp usage(results) do
    results |> Enum.map(& &1.usage) |> Usage.sum()
  end

  defp persisted_results(results) do
    Enum.reduce_while(results, {:ok, []}, fn result, {:ok, acc} ->
      case Result.from_map(result) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end)
  end

  defp persisted_status("ok"), do: {:ok, :ok}
  defp persisted_status("partial"), do: {:ok, :partial}
  defp persisted_status("failed"), do: {:ok, :failed}
  defp persisted_status("cancelled"), do: {:ok, :cancelled}
  defp persisted_status("timeout"), do: {:ok, :timeout}
  defp persisted_status(status), do: {:error, {:unknown_group_status, status}}
end
