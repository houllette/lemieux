defmodule Lemieux.Tool.Exposure do
  @moduledoc """
  Defer catalog disclosure until a host-selected session request count.

  This changes model visibility, never execution authority: a host's tool and
  approval policy still governs every call. A threshold of zero exposes tools
  immediately. The request snapshot records actual visible bytes and names
  deferred here; the prepared harness still describes the available catalog.
  No model request, loader tool or extra prompt is needed to reveal the tool.
  """
  alias Lemieux.Harness
  alias Lemieux.Session
  alias Lemieux.Tool

  @spec after_requests(harness :: Harness.t(), names :: [String.t()], count :: non_neg_integer()) ::
          Harness.t()
  def after_requests(harness, _names, 0), do: harness

  def after_requests(harness, names, count) when is_integer(count) and count in 1..1_000 do
    Harness.append_hooks(harness,
      prepare_next_turn: fn request, context ->
        if Session.budget(context.session).requests < count do
          tools = Enum.reject(request.tools, &(Tool.name(&1) in names))
          deferred = Enum.uniq(Map.get(request.context, :deferred_tools, []) ++ names)

          {:ok,
           %{request | tools: tools, context: Map.put(request.context, :deferred_tools, deferred)}}
        else
          {:ok, request}
        end
      end
    )
  end

  def after_requests(_harness, _names, _count),
    do: raise(ArgumentError, "exposure request count must be 0..1000")
end
