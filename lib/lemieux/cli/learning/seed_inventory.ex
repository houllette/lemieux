defmodule Lemieux.CLI.Learning.SeedInventory do
  @moduledoc false

  @doc "Checks that every declared seed stream retained experience before target dispatch."
  @spec check(libraries :: map(), required_streams :: [String.t()]) ::
          {:ok, map()} | {:error, map()}
  def check(libraries, required_streams) do
    counts = Map.new(libraries, fn {stream, lessons} -> {stream, length(lessons)} end)
    required = Enum.sort(Enum.uniq(required_streams))
    empty = Enum.filter(required, &(Map.get(counts, &1, 0) == 0))

    # A recipe and digest can faithfully freeze an empty inventory. That is
    # provenance, not a positive control for seeded transfer (the Luna study
    # on 2026-10-20 retained no seed lessons). Stop before expensive targets.
    receipt = %{
      "schema_version" => 1,
      "required_streams" => required,
      "lesson_counts" => counts,
      "empty_required_streams" => empty,
      "passed" => empty == [],
      "interpretation" => "Presence only; lesson relevance and benefit remain unconfirmed."
    }

    if empty == [], do: {:ok, receipt}, else: {:error, receipt}
  end
end
