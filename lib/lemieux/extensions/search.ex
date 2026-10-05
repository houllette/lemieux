defmodule Lemieux.Extensions.Search do
  @moduledoc """
  Adds `grep` and `glob` to the catalog, beside `read`.

  The library's default catalog stays the four tools `Lemieux.Tool`
  describes; searching is an opinion a host opts into, and `lmx` does by
  default. The two go in right after `read` so the model sees the looking
  tools together, and a catalog that already has either keeps its own.

  A catalog without `read` is a profile that chose not to let the model look
  at files (`Lemieux.Extensions.Elixir` is one), and gets no search tools
  from here either: a search is a way of reading.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tools.Glob
  alias Lemieux.Tools.Grep

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, _state) do
    Harness.update_tools(harness, &add/1)
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
