defmodule Lmx.Update.SignatureTest do
  use ExUnit.Case, async: true
  alias Lmx.Update.Signature

  # RFC 8032, section 7.1, TEST 3.
  @secret Base.decode16!("c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7",
            case: :lower
          )
  @public Base.decode16!("fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025",
            case: :lower
          )
  @message <<0xAF, 0x82>>
  @signature Base.decode16!(
               "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac" <>
                 "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a",
               case: :lower
             )

  test "signs and verifies RFC 8032 vectors in the .sig file format" do
    assert Signature.public_key(@secret) == @public
    assert Signature.sign(@message, @secret) == Base.encode64(@signature) <> "\n"
    assert :ok = Signature.verify(@message, Base.encode64(@signature) <> "\n", @public)
    # Surrounding whitespace is tolerated; any change to message or signature is not.
    assert :ok = Signature.verify(@message, "  " <> Base.encode64(@signature) <> "\r\n", @public)

    assert {:error, :signature_invalid} =
             Signature.verify(<<0xAF>>, Signature.sign(@message, @secret), @public)

    <<first, rest::binary>> = @signature

    assert {:error, :signature_invalid} =
             Signature.verify(
               @message,
               Base.encode64(<<Bitwise.bxor(first, 1), rest::binary>>),
               @public
             )

    {other, _} = :crypto.generate_key(:eddsa, :ed25519)

    assert {:error, :signature_invalid} =
             Signature.verify(@message, Signature.sign(@message, @secret), other)
  end

  test "signature files must be padded base64 of exactly 64 bytes" do
    for text <- [
          "",
          "not base64",
          Base.encode64(:binary.copy(<<1>>, 63)),
          Base.encode64(:binary.copy(<<1>>, 64), padding: false),
          String.duplicate("A", 2_000)
        ] do
      assert {:error, :signature_invalid} = Signature.decode(text)
    end

    assert {:ok, <<_::binary-size(64)>>} = Signature.decode(Base.encode64(@signature) <> "\n")
  end

  test "key files hold UNSET or a padded base64 32-byte key" do
    assert Signature.parse_public_key("UNSET\n") == :unset
    assert Signature.parse_public_key(Base.encode64(@public) <> "\n") == {:ok, @public}
    assert Signature.encode_public_key(@public) == Base.encode64(@public)

    for text <- ["", "unset", Base.encode64(<<1, 2, 3>>), Base.encode64(@public, padding: false)] do
      assert Signature.parse_public_key(text) == {:error, :invalid_public_key}
    end
  end

  test "the key compiled into this build is the committed release-signing.pub" do
    committed =
      "../../../release-signing.pub" |> Path.expand(__DIR__) |> File.read!() |> String.trim()

    assert Signature.pinned_text() == committed

    case Signature.parse_public_key(committed) do
      :unset -> assert Signature.pinned() == :unset
      {:ok, key} -> assert Signature.pinned() == {:ok, key}
    end
  end
end
