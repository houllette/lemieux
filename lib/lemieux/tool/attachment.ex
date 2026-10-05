defmodule Lemieux.Tool.Attachment do
  @moduledoc """
  An image or a document a tool hands the model beside its text.

  ## The shape, and why it is not new

      %{
        "kind" => "image" | "document",
        "media_type" => "image/png",
        "data" => base64,
        "bytes" => byte_size(base64),
        "size" => byte_size(raw),
        "path" => "shot.png"
      }

  JSON with string keys, because it is written into the tool result's
  transcript entry and read back on every resume. It is the shape
  `Lemieux.Reference` already gives an `@path` attachment on a prompt, on
  purpose: the estimator that must not price a screenshot as a megabyte of
  prose (`Lemieux.Reference.estimable/1`), the provider seam that turns one
  into an image block, and the compaction projection that stops re-sending
  old ones all already know it. A second shape would have needed a second
  copy of each, and the copy that was forgotten would be the one that sent
  base64 to a model as text.

  `"size"` is the file's own size, which is what a person reading
  "120 KB" means; `"bytes"` is the encoded length, which is what a request
  carries.

  ## The limits

  An image over #{3_500_000} bytes is not attached: that is roughly
  Anthropic's per-image ceiling once base64 has added its third, and the
  provider's answer to an oversized image is a 400 for the whole request —
  including the conversation that was fine — on every request after it,
  because the transcript would carry the image forever. A document (a PDF)
  may be larger, up to #{5_000_000} bytes, since providers take much bigger
  ones; the cap there is the transcript's, which stores the bytes once. At
  most #{5} attachments ride on one result: the byte caps bound what they cost
  together, this bounds how many separate things the model is handed at once.
  Whatever is left out is named in the result's text rather than dropped
  silently, because a model told nothing came back concludes the tool
  returned nothing.
  """

  @image_types %{
    ".gif" => "image/gif",
    ".jpeg" => "image/jpeg",
    ".jpg" => "image/jpeg",
    ".png" => "image/png",
    ".webp" => "image/webp"
  }

  @document_types %{".pdf" => "application/pdf"}

  @image_media_types Map.values(@image_types) |> Enum.uniq()
  @document_media_types Map.values(@document_types)

  @max_image_bytes 3_500_000
  @max_document_bytes 5_000_000
  @max_count 5

  @typedoc "A transcript-safe attachment; see the module documentation for its keys."
  @type t :: %{required(String.t()) => term()}

  @typedoc "Kinds of input a model may accept, as the model catalog names them."
  @type modalities :: [atom()] | :unknown

  @doc """
  Builds an attachment from raw bytes.

  `kind` is `:image` or `:document`. `:path` names it for a person and, for a
  document, is the file name a provider is given.
  """
  @spec new(
          kind :: :image | :document,
          media_type :: String.t(),
          bytes :: binary(),
          opts :: [path: String.t()]
        ) :: t()
  def new(kind, media_type, bytes, opts \\ [])
      when kind in [:image, :document] and is_binary(media_type) and is_binary(bytes) do
    data = Base.encode64(bytes)

    %{
      "kind" => Atom.to_string(kind),
      "media_type" => media_type,
      "data" => data,
      "bytes" => byte_size(data),
      "size" => byte_size(bytes),
      "path" => Keyword.get(opts, :path, "")
    }
  end

  @doc """
  What a path names by its extension: `{:image, media_type}`,
  `{:document, media_type}`, or `nil` for anything else.
  """
  @spec kind_of(path :: String.t()) :: {:image | :document, String.t()} | nil
  def kind_of(path) when is_binary(path) do
    extension = path |> Path.extname() |> String.downcase()

    cond do
      Map.has_key?(@image_types, extension) ->
        {:image, Map.fetch!(@image_types, extension)}

      Map.has_key?(@document_types, extension) ->
        {:document, Map.fetch!(@document_types, extension)}

      true ->
        nil
    end
  end

  @doc """
  The media type the bytes themselves announce, from their magic number.

  An extension is a claim; these are the first bytes every decoder checks. A
  `.png` that is really a JPEG is sent as a JPEG, and a `.png` that is really
  text is not sent as an image at all — a provider refuses a request whose
  image does not decode, and it refuses every later request that still
  carries it.
  """
  @spec sniff(bytes :: binary()) :: String.t() | nil
  def sniff(<<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _rest::binary>>), do: "image/png"
  def sniff(<<0xFF, 0xD8, 0xFF, _rest::binary>>), do: "image/jpeg"
  def sniff(<<"GIF87a", _rest::binary>>), do: "image/gif"
  def sniff(<<"GIF89a", _rest::binary>>), do: "image/gif"
  def sniff(<<"RIFF", _size::binary-size(4), "WEBP", _rest::binary>>), do: "image/webp"
  def sniff(<<"%PDF-", _rest::binary>>), do: "application/pdf"
  def sniff(_bytes), do: nil

  @doc "Whether `media_type` is one this module attaches as an image."
  @spec image_type?(media_type :: String.t()) :: boolean()
  def image_type?(media_type), do: media_type in @image_media_types

  @doc "Whether `media_type` is one this module attaches as a document."
  @spec document_type?(media_type :: String.t()) :: boolean()
  def document_type?(media_type), do: media_type in @document_media_types

  @doc "The largest file, in bytes, attached as `kind`."
  @spec max_bytes(kind :: :image | :document) :: pos_integer()
  def max_bytes(:image), do: @max_image_bytes
  def max_bytes(:document), do: @max_document_bytes

  @doc "The most attachments one tool result carries."
  @spec max_count() :: pos_integer()
  def max_count, do: @max_count

  @doc """
  The model-catalog modality an attachment needs: `:image` or `:pdf`.
  """
  @spec modality(attachment :: t()) :: :image | :pdf | nil
  def modality(%{"kind" => "image"}), do: :image
  def modality(%{"kind" => "document", "media_type" => "application/pdf"}), do: :pdf
  def modality(_attachment), do: nil

  @doc """
  Whether a model accepting `modalities` can be sent `attachment`.

  `:unknown` answers no. This is the question for something a *tool*
  produced: an image sent to a model that cannot read it is a provider
  refusal on this request and on every later one, because the transcript
  keeps the image. Absent catalog data is not evidence of a capability.
  """
  @spec accepted?(attachment :: t(), modalities :: modalities()) :: boolean()
  def accepted?(_attachment, :unknown), do: false

  def accepted?(attachment, modalities) when is_list(modalities) do
    case modality(attachment) do
      nil -> false
      needed -> needed in modalities
    end
  end

  @doc """
  Whether `value` is a well-formed attachment: an image or a document whose
  data is a base64 string.
  """
  @spec valid?(value :: term()) :: boolean()
  def valid?(%{"kind" => kind, "media_type" => media_type, "data" => data} = value)
      when kind in ["image", "document"] and is_binary(media_type) and is_binary(data) do
    Enum.all?(value, fn {key, _value} -> is_binary(key) end)
  end

  def valid?(_value), do: false

  @doc """
  Applies the count and size limits, in order.

  Returns what is kept and one sentence per attachment left out, for the
  result's text.
  """
  @spec limit(attachments :: [t()]) :: {[t()], [String.t()]}
  def limit(attachments) when is_list(attachments) do
    {kept, notes, _count} =
      Enum.reduce(attachments, {[], [], 0}, fn attachment, {kept, notes, count} ->
        cond do
          oversized?(attachment) ->
            {kept, [oversize_note(attachment) | notes], count}

          count >= @max_count ->
            {kept, [count_note(attachment) | notes], count}

          true ->
            {[attachment | kept], notes, count + 1}
        end
      end)

    {Enum.reverse(kept), Enum.reverse(notes)}
  end

  defp oversized?(%{"kind" => "image"} = attachment), do: size(attachment) > @max_image_bytes

  defp oversized?(%{"kind" => "document"} = attachment),
    do: size(attachment) > @max_document_bytes

  defp oversize_note(%{"kind" => kind} = attachment) do
    limit = if kind == "image", do: @max_image_bytes, else: @max_document_bytes

    "[#{label(attachment)} is #{human_size(size(attachment))}, over the " <>
      "#{human_size(limit)} limit for attaching #{kind}s; it is not attached]"
  end

  defp count_note(attachment) do
    "[#{label(attachment)} is not attached: one result carries at most " <>
      "#{@max_count} attachments]"
  end

  @doc """
  The file's own size in bytes, from `"size"` or, for an attachment written
  without one, from the base64 length.
  """
  @spec size(attachment :: t()) :: non_neg_integer()
  def size(%{"size" => size}) when is_integer(size) and size >= 0, do: size

  def size(%{"data" => data}) when is_binary(data) do
    padding =
      cond do
        String.ends_with?(data, "==") -> 2
        String.ends_with?(data, "=") -> 1
        true -> 0
      end

    max(div(byte_size(data) * 3, 4) - padding, 0)
  end

  def size(_attachment), do: 0

  @doc """
  A short description for the text beside an attachment:
  `"image/png, 120 KB, 800×600"`.
  """
  @spec describe(attachment :: t()) :: String.t()
  def describe(%{"media_type" => media_type} = attachment) do
    [media_type, human_size(size(attachment)), dimensions_text(attachment)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp dimensions_text(%{"kind" => "image", "data" => data, "media_type" => media_type}) do
    with {:ok, bytes} <- Base.decode64(data),
         {width, height} <- dimensions(bytes, media_type) do
      "#{width}×#{height}"
    else
      _unknown -> nil
    end
  end

  defp dimensions_text(_attachment), do: nil

  defp label(%{"path" => path} = attachment) when is_binary(path) and path != "",
    do: "#{kind_word(attachment)} #{path}"

  defp label(attachment), do: "an #{kind_word(attachment)}"

  defp kind_word(%{"kind" => "document"}), do: "document"
  defp kind_word(_attachment), do: "image"

  @doc ~s(Bytes as a person reads them: "812 B", "120 KB", "3.4 MB".)
  @spec human_size(bytes :: non_neg_integer()) :: String.t()
  def human_size(bytes) when bytes < 1_000, do: "#{bytes} B"
  def human_size(bytes) when bytes < 1_000_000, do: "#{round(bytes / 1_000)} KB"
  def human_size(bytes), do: "#{Float.round(bytes / 1_000_000, 1)} MB"

  @doc """
  An image's pixel dimensions, read from its header, or `nil`.

  Only the header: a model is told "800×600" so it knows what it is looking
  at, and finding that out must not mean decoding the image.
  """
  @spec dimensions(bytes :: binary(), media_type :: String.t()) ::
          {pos_integer(), pos_integer()} | nil
  def dimensions(
        <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, _length::32, "IHDR", width::32, height::32,
          _rest::binary>>,
        "image/png"
      ),
      do: positive(width, height)

  def dimensions(
        <<"GIF8", _version::binary-size(2), width::little-16, height::little-16, _::binary>>,
        "image/gif"
      ),
      do: positive(width, height)

  def dimensions(<<"RIFF", _size::binary-size(4), "WEBP", chunk::binary>>, "image/webp"),
    do: webp(chunk)

  def dimensions(<<0xFF, 0xD8, rest::binary>>, "image/jpeg"), do: jpeg(rest)
  def dimensions(_bytes, _media_type), do: nil

  defp webp(
         <<"VP8X", _size::binary-size(4), _flags::binary-size(4), width::little-24,
           height::little-24, _::binary>>
       ),
       do: positive(width + 1, height + 1)

  defp webp(
         <<"VP8 ", _size::binary-size(4), _tag::binary-size(3), 0x9D, 0x01, 0x2A,
           width::little-16, height::little-16, _::binary>>
       ),
       do: positive(Bitwise.band(width, 0x3FFF), Bitwise.band(height, 0x3FFF))

  defp webp(<<"VP8L", _size::binary-size(4), 0x2F, bits::little-32, _::binary>>) do
    width = Bitwise.band(bits, 0x3FFF) + 1
    height = Bitwise.band(Bitwise.bsr(bits, 14), 0x3FFF) + 1
    positive(width, height)
  end

  defp webp(_chunk), do: nil

  # Walks the marker segments to the first start-of-frame. Fill bytes and the
  # markers that carry no length are stepped over; DHT, JPG and DAC share the
  # SOF range and are not frames.
  defp jpeg(<<0xFF, 0xFF, rest::binary>>), do: jpeg(<<0xFF, rest::binary>>)

  defp jpeg(<<0xFF, marker, rest::binary>>) when marker in 0xD0..0xD7 or marker == 0x01,
    do: jpeg(rest)

  defp jpeg(<<0xFF, marker, _length::16, _precision, height::16, width::16, _::binary>>)
       when marker in 0xC0..0xCF and marker not in [0xC4, 0xC8, 0xCC],
       do: positive(width, height)

  defp jpeg(<<0xFF, _marker, length::16, rest::binary>>) when length >= 2 do
    skip = length - 2

    case rest do
      <<_segment::binary-size(^skip), next::binary>> -> jpeg(next)
      _truncated -> nil
    end
  end

  defp jpeg(_bytes), do: nil

  defp positive(width, height) when width > 0 and height > 0, do: {width, height}
  defp positive(_width, _height), do: nil
end
