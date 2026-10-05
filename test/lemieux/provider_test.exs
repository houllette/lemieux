defmodule Lemieux.ProviderTest do
  use ExUnit.Case, async: true

  alias Lemieux.Provider
  alias Lemieux.Providers.Scripted

  defmodule Sighted do
    @moduledoc false
    def input_modalities(:sighted, "any:model"), do: [:text, :image]
    def input_modalities(:sighted, _model), do: :unknown
  end

  describe "input_modalities/2" do
    test "asks a provider that implements the callback" do
      assert Provider.input_modalities({Sighted, :sighted}, "any:model") == [:text, :image]
      assert Provider.input_modalities({Sighted, :sighted}, "other:model") == :unknown
    end

    # A provider without the callback cannot say, and a tool must not guess:
    # an image sent to a model that cannot read it is refused on every later
    # request that still carries it.
    test "is unknown for a provider without the callback" do
      assert Provider.input_modalities(Scripted.new([]), "any:model") == :unknown
    end
  end
end
