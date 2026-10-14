defmodule Lemieux.Extensions.Search do
  @moduledoc """
  Adds `grep` and `glob` to the catalog, beside `read`.

  The library's default catalog stays the four tools `Lemieux.Tool`
  describes; searching is an opinion a host opts into, and `lmx` does by
  default. The two go in right after `read` so the model sees the looking
  tools together, and a catalog that already has either keeps its own.

  `glob_after_requests` defaults to 1: `grep` is immediate, while the glob
  schema appears after one session request. Set it to 0 for immediate exposure.
  This is catalog disclosure, not a restriction on execution authority.

  A catalog without `read` is a profile that chose not to let the model look
  at files (`Lemieux.Extensions.Elixir` is one), and gets no search tools
  from here either: a search is a way of reading.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tool.Exposure
  alias Lemieux.Tools.Glob
  alias Lemieux.Tools.Grep

  @impl Lemieux.Extension
  def init(opts) do
    count = Keyword.get(opts, :glob_after_requests, 1)

    if is_integer(count) and count in 0..1_000,
      do: {:ok, %{glob_after_requests: count}},
      else: {:error, "glob_after_requests must be 0..1000"}
  end

  @impl Lemieux.Extension
  def describe(state), do: %{"glob_after_requests" => state.glob_after_requests}

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, state) do
    count = if is_map(state), do: state.glob_after_requests, else: 1
    harness |> Harness.update_tools(&add/1) |> Exposure.after_requests(["glob"], count)
  end

  defp add(tools) do
    names = MapSet.new(tools, &Tool.name/1)
    missing = Enum.reject([Grep, Glob], &MapSet.member?(names, Tool.name(&1)))

    case {MapSet.member?(names, "read"), missing} do
      {false, _missing} -> tools
      {true, []} -> tools
      {true, missing} -> after_read(tools, missing)
    end
  end

  defp after_read(tools, missing) do
    {before, [read | rest]} = Enum.split_while(tools, &(Tool.name(&1) != "read"))
    before ++ [read | missing] ++ rest
  end
end
