defmodule Lemieux.IDTest do
  use ExUnit.Case, async: true

  alias Lemieux.ID

  describe "generate/0" do
    test "produces a 26-character Crockford base32 string" do
      id = ID.generate()

      assert byte_size(id) == 26
      assert id =~ ~r/\A[0-9ABCDEFGHJKMNPQRSTVWXYZ]{26}\z/
    end

    test "produces distinct ids" do
      ids = for _ <- 1..1000, do: ID.generate()

      assert ids |> Enum.uniq() |> length() == 1000
    end

    test "sorts lexicographically by generation time" do
      # The whole reason for a ULID over a UUID: sorting the session directory
      # by name has to be sorting it by age.
      earlier = ID.generate(1_700_000_000_000)
      later = ID.generate(1_700_000_001_000)

      assert earlier < later
    end
  end

  describe "timestamp/1" do
    test "recovers the millisecond the id was generated at" do
      assert ID.timestamp(ID.generate(1_700_000_000_123)) == 1_700_000_000_123
    end

    test "rejects a string that is not an id" do
      assert ID.timestamp("nope") == :error
      # I and L are not in the Crockford alphabet.
      assert ID.timestamp(String.duplicate("I", 26)) == :error
    end
  end
end
