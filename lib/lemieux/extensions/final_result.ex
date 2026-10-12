defmodule Lemieux.Extensions.FinalResult do
  @moduledoc """
  Guides a tool-using session toward a JSON final answer under a host contract.

  This does not switch the provider to an object-only operation, which could
  remove tool use on a route that implements structured output differently.
  `Lemieux.StructuredResult` validates the final answer independently; a prompt
  instruction alone is never reported as a validated result.
  """
  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Harness
  alias Lemieux.StructuredResult

  @impl true
  def init(opts), do: StructuredResult.new(Keyword.fetch!(opts, :schema))

  @impl true
  def apply(harness, contract) do
    Harness.append_hooks(harness,
      prepare_next_turn: fn request, _context ->
        instruction =
          "Use tools as needed. Your final answer must be only a JSON object conforming to this schema, without Markdown fences:\n" <>
            JSON.encode!(contract.schema)

        {:ok, %{request | system: Enum.join([request.system || "", instruction], "\n\n")}}
      end
    )
  end

  @impl true
  def describe(contract), do: %{"schema_sha256" => contract.digest}
end
