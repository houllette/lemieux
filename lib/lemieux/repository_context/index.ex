defmodule Lemieux.RepositoryContext.Index do
  @moduledoc """
  An immutable, host-owned semantic snapshot implementing `Lemieux.RepositoryContext.Source`.

  Hosts may populate this from an index or reviewed language-server responses,
  or use `Lemieux.RepositoryContext.Elixir.build/4`. No snapshot is discovered,
  loaded or executed from repository configuration. Replace it explicitly on
  update; configured tools are supplied again on resume. This is source context,
  not retrieval memory: nothing is added to user-curated memory or persisted.
  """
  @behaviour Lemieux.RepositoryContext.Source

  @type t :: %__MODULE__{
          items: list(),
          revision: String.t(),
          indexed_at: String.t(),
          complete?: boolean(),
          files: map(),
          limitations: [String.t()]
        }
  defstruct [:revision, :indexed_at, items: [], complete?: true, files: %{}, limitations: []]

  @doc "Builds a snapshot. Item validation happens again at disclosure."
  @spec new(items :: list(), opts :: keyword()) :: t()
  def new(items, opts) when is_list(items) do
    %__MODULE__{
      items: items,
      revision: Keyword.fetch!(opts, :revision),
      indexed_at:
        Keyword.get_lazy(opts, :indexed_at, fn -> DateTime.utc_now() |> DateTime.to_iso8601() end),
      complete?: Keyword.get(opts, :complete?, true),
      limitations: Keyword.get(opts, :limitations, [])
    }
  end

  @impl true
  def query(%__MODULE__{} = index, request) do
    # Filter the host snapshot before the disclosure cap, so a definition late
    # in a large manifest can be found without reading every unrelated file.
    # The consumer still validates records, permissions, digests and limits.
    items = Stream.filter(index.items, &matches?(&1, request))

    {:ok,
     index
     |> Map.take([:revision, :indexed_at, :complete?, :limitations])
     |> Map.put(:items, items)}
  end

  defp matches?(%{kind: kind, symbol: symbol, path: path}, request)
       when is_binary(symbol) and is_binary(path) do
    if String.valid?(symbol) and String.valid?(path) do
      in_path? =
        is_nil(request.path) or path == request.path or
          String.starts_with?(path, request.path <> "/")

      in_operation?(kind, request.operation) and in_path? and
        String.contains?(String.downcase(symbol), String.downcase(request.query))
    else
      true
    end
  end

  defp matches?(_malformed, _request), do: true

  # Maps retain reference edges for ranking. Other queries must not spend
  # their candidate allowance on a different record kind with the same name.
  defp in_operation?(kind, "map"), do: kind in ~w(definition symbol reference dependency)
  defp in_operation?(kind, "definitions"), do: kind == "definition"
  defp in_operation?(kind, "references"), do: kind == "reference"
  defp in_operation?(kind, "dependencies"), do: kind == "dependency"
  defp in_operation?(kind, "symbols"), do: kind in ~w(definition symbol)
  defp in_operation?(kind, "diagnostics"), do: kind == "diagnostic"
  defp in_operation?(_kind, _operation), do: false
end
