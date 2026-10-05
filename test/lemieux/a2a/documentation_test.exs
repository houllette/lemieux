defmodule Lemieux.A2A.DocumentationTest do
  @moduledoc """
  The A2A modules are what a host wires into its own HTTP stack, so their
  public functions are the documentation a host reads. They once shipped 37
  public functions with no `@doc` between them; this keeps the next one from
  arriving the same way.
  """

  use ExUnit.Case, async: true

  test "every public function in a documented A2A module has documentation" do
    {:ok, modules} = :application.get_key(:lemieux, :modules)

    undocumented =
      for module <- modules,
          String.starts_with?(inspect(module), "Lemieux.A2A"),
          {:docs_v1, _, _, _, moduledoc, _, docs} <- [Code.fetch_docs(module)],
          moduledoc != :hidden,
          {{:function, name, arity}, _anno, _signature, :none, _meta} <- docs,
          do: "#{inspect(module)}.#{name}/#{arity}"

    assert undocumented == []
  end
end
