defmodule Lemieux.Extensions.RepositoryContext do
  @moduledoc """
  Opt-in semantic repository context, beside the ordinary search/read tools.

  Options are `Lemieux.RepositoryContext.new/1`'s. No indexer, language server,
  repository script or model request is started during assembly. A profile
  without `read` gains no file-reading capability from this extension.
  """
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]
  alias Lemieux.Extensions.Search
  alias Lemieux.Harness
  alias Lemieux.RepositoryContext
  alias Lemieux.Tool

  @impl true
  def init(opts) do
    {:ok, RepositoryContext.new(opts)}
  rescue
    error in [ArgumentError, KeyError] -> {:error, Exception.message(error)}
  end

  @impl true
  def apply(%Harness{} = harness, tool) do
    if Enum.any?(harness.tools || Lemieux.Tools.default(), &(Tool.name(&1) == "read")) do
      harness
      |> search_fallback()
      |> Harness.update_tools(&insert(&1, tool))
    else
      harness
    end
  end

  defp search_fallback(harness) do
    names = Enum.map(harness.tools || Lemieux.Tools.default(), &Tool.name/1)

    if "grep" in names and "glob" in names,
      do: harness,
      else: Search.apply(harness, %{glob_after_requests: 1})
  end

  defp insert(tools, tool) do
    if Enum.any?(tools, &(Tool.name(&1) == "repository_context")),
      do: tools,
      else: tools ++ [tool]
  end

  @impl true
  def describe(tool) do
    %{
      "repositories" => Enum.map(tool.repositories, & &1.id),
      "limits" => Map.new(tool.limits, fn {key, value} -> {Atom.to_string(key), value} end)
    }
  end
end
