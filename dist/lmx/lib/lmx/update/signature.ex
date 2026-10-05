defmodule Lmx.Update.Signature do
  @moduledoc """
  Ed25519 signatures over release assets, checked against a public key that is
  compiled into this build.

  An installed `lmx` downloads `update.json` from the same GitHub release that
  serves the archives. A checksum in that manifest only proves an archive is
  the one the manifest names: whoever can upload a release asset (a stolen
  maintainer token, a compromised account) could replace both, and every
  installed `lmx` would then install their code within the hour. The
  maintainer therefore signs `update.json` and `SHA256SUMS` with a key kept
  offline, and this module checks those signatures with the public half,
  read from `dist/lmx/release-signing.pub` when the release is compiled. A
  release origin that is compromised cannot also replace the key a running
  `lmx` trusts.

  The formats are shared with `scripts/install.py` and the maintainer tasks
  (`mix lmx.release.keygen`, `sign`, `verify`, `sign_draft`):

    * `release-signing.pub` holds one line: the standard padded base64 of the
      raw 32-byte public key, or exactly `UNSET` until the maintainer has run
      `mix lmx.release.keygen`. A build compiled with `UNSET` verifies nothing
      and so installs no update; it can still say one exists.
    * `NAME.sig` holds the standard padded base64 of the raw 64-byte
      signature over the exact bytes of `NAME`, followed by a newline.

  Verification fails closed: a missing, malformed or wrong signature is an
  error for the caller to refuse on, never a warning to install through.
  """

  @key_file Path.expand("../../../release-signing.pub", __DIR__)
  @external_resource @key_file
  @pinned @key_file |> File.read!() |> String.trim()

  # A malformed key would compile into a release that rejects every update
  # it is ever offered, with no way to fix it from the field. Fail the build.
  unless @pinned == "UNSET" or match?({:ok, <<_::binary-size(32)>>}, Base.decode64(@pinned)) do
    raise ArgumentError,
          "#{@key_file} must hold UNSET or the padded base64 of a 32-byte Ed25519 public key"
  end

  @typedoc "A raw 32-byte Ed25519 public key."
  @type public_key :: <<_::256>>

  @typedoc "A raw 32-byte Ed25519 private key (the seed)."
  @type private_key :: <<_::256>>

  @doc "The release-signing public key compiled into this build, or `:unset`."
  @spec pinned() :: {:ok, public_key()} | :unset
  def pinned do
    case parse_public_key(@pinned) do
      {:ok, key} -> {:ok, key}
      :unset -> :unset
    end
  end

  @doc "The pinned key file's text as compiled into this build, trimmed."
  @spec pinned_text() :: String.t()
  def pinned_text, do: @pinned

  @doc "Parses `release-signing.pub` text: a padded base64 public key, or `UNSET`."
  @spec parse_public_key(text :: String.t()) ::
          {:ok, public_key()} | :unset | {:error, :invalid_public_key}
  def parse_public_key(text) when is_binary(text), do: text |> String.trim() |> decode_key()

  defp decode_key("UNSET"), do: :unset

  defp decode_key(encoded) do
    case Base.decode64(encoded) do
      {:ok, <<_::binary-size(32)>> = key} -> {:ok, key}
      _invalid -> {:error, :invalid_public_key}
    end
  end

  @doc "Encodes a public key as one `release-signing.pub` line, without the newline."
  @spec encode_public_key(key :: public_key()) :: String.t()
  def encode_public_key(<<_::binary-size(32)>> = key), do: Base.encode64(key)

  @doc "Decodes a `.sig` file's contents into a raw 64-byte signature."
  @spec decode(text :: binary()) :: {:ok, <<_::512>>} | {:error, :signature_invalid}
  def decode(text) when is_binary(text) and byte_size(text) <= 1_024 do
    case Base.decode64(String.trim(text)) do
      {:ok, <<_::binary-size(64)>> = signature} -> {:ok, signature}
      _invalid -> {:error, :signature_invalid}
    end
  end

  def decode(_text), do: {:error, :signature_invalid}

  @doc """
  Checks `signature` (a `.sig` file's contents) over the exact bytes of `body`.
  """
  @spec verify(body :: binary(), signature :: binary(), key :: public_key()) ::
          :ok | {:error, :signature_invalid}
  def verify(body, signature, <<_::binary-size(32)>> = key) when is_binary(body) do
    with {:ok, raw} <- decode(signature),
         true <- :crypto.verify(:eddsa, :none, body, raw, [key, :ed25519]) do
      :ok
    else
      _invalid -> {:error, :signature_invalid}
    end
  end

  @doc "Signs `body`, returning the contents of its `.sig` file. Maintainer tooling only."
  @spec sign(body :: binary(), private_key :: private_key()) :: String.t()
  def sign(body, <<_::binary-size(32)>> = private_key) when is_binary(body) do
    signature = :crypto.sign(:eddsa, :none, body, [private_key, :ed25519])
    Base.encode64(signature) <> "\n"
  end

  @doc "The public key belonging to a private key."
  @spec public_key(private_key :: private_key()) :: public_key()
  def public_key(<<_::binary-size(32)>> = private_key) do
    {public, ^private_key} = :crypto.generate_key(:eddsa, :ed25519, private_key)
    public
  end
end
