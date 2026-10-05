defmodule Lemieux.SessionAttachmentsTest do
  @moduledoc """
  Images and documents a tool returns, from the call to the transcript to the
  request that carries them.
  """

  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool.Attachment

  @moduletag :tmp_dir

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 8::32, 8::32, 8, 6, 0, 0, 0>>

  # Takes a picture and says which modalities its context reported, so a test
  # can see what the session told it.
  defmodule Camera do
    @moduledoc false
    @behaviour Lemieux.Tool

    alias Lemieux.Tool.Attachment
    alias Lemieux.Tool.Result

    @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 8::32, 8::32, 8, 6, 0, 0, 0>>

    @impl true
    def name, do: "camera"
    @impl true
    def description, do: "Takes a picture."
    @impl true
    def schema, do: %{"type" => "object", "properties" => %{}}

    # Each picture is a different one, as a browser's screenshots are: six
    # identical answers in a row would be the session's loop guard's business.
    @impl true
    def run(_args, context) do
      modalities = Map.get(context, :input_modalities)

      {:ok,
       Result.new("[image: picture #{context.call_id}] modalities=#{inspect(modalities)}",
         attachments: [Attachment.new(:image, "image/png", @png, path: "picture.png")]
       )}
    end
  end

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_attachments_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    %{runtime: runtime, store: JSONL.new(tmp_dir)}
  end

  defp start_session(context, script, opts) do
    provider = Scripted.new(script)

    {:ok, session} =
      [
        supervisor: context.runtime,
        provider: provider,
        store: context.store,
        model: "test:model",
        subscriber: self(),
        tools: [Camera]
      ]
      |> Keyword.merge(opts)
      |> Lemieux.start_session()

    {session, provider}
  end

  defp run(session, text) do
    id = Session.id(session)
    :ok = Session.prompt(session, text)
    assert_receive {:lemieux, ^id, {:finished, _reason}}, 5_000
  end

  defp tool_results(session),
    do:
      session
      |> Session.snapshot()
      |> Map.fetch!(:entries)
      |> Enum.filter(&(&1.type == :tool_result))

  test "a model that views images gets the picture, recorded once and sent with the result",
       context do
    {session, provider} =
      start_session(
        context,
        [Scripted.tool_call("c1", "camera", %{}), Scripted.complete("a cat")],
        input_modalities: [:text, :image]
      )

    run(session, "what do you see?")

    assert [result] = tool_results(session)
    assert result.payload["output"] =~ "modalities=[:text, :image]"

    assert [%{"kind" => "image", "path" => "picture.png"} = attachment] =
             result.payload["attachments"]

    assert Base.decode64!(attachment["data"]) == @png

    # The request after the call carries the attachment the provider encodes.
    assert [_first, second] = Scripted.requests(provider)

    assert Enum.any?(
             second.entries,
             &(&1.type == :tool_result and match?([_], &1.payload["attachments"]))
           )
  end

  # An image in the transcript is sent on every later request; to a model
  # that cannot take one, that is every later request refused.
  test "a model that cannot view images is told what came back instead", context do
    {session, _provider} =
      start_session(
        context,
        [Scripted.tool_call("c1", "camera", %{}), Scripted.complete("ok")],
        input_modalities: [:text]
      )

    run(session, "what do you see?")

    assert [result] = tool_results(session)
    refute Map.has_key?(result.payload, "attachments")

    assert result.payload["output"] =~
             "[1 attachment from this result is not shown: the current model cannot read them]"

    assert result.payload["output_bytes"] == byte_size(result.payload["output"])
  end

  test "a provider that cannot say what its model reads leaves tools answering in words",
       context do
    {session, _provider} =
      start_session(
        context,
        [Scripted.tool_call("c1", "camera", %{}), Scripted.complete("ok")],
        []
      )

    run(session, "what do you see?")

    assert [result] = tool_results(session)
    assert result.payload["output"] =~ "modalities=:unknown"
    refute Map.has_key?(result.payload, "attachments")
    assert result.payload["output"] =~ "does not know whether its model can read them"
  end

  test "only the newest pictures are resent, shed a batch at a time", context do
    calls = for n <- 1..6, do: Scripted.tool_call("c#{n}", "camera", %{})

    {session, provider} =
      start_session(context, calls ++ [Scripted.complete("done")],
        input_modalities: [:text, :image],
        keep_media: 2
      )

    run(session, "take six")

    last = provider |> Scripted.requests() |> List.last()

    carrying =
      Enum.filter(
        last.entries,
        &(&1.type == :tool_result and Map.has_key?(&1.payload, "attachments"))
      )

    # Six carry images and two are kept: four are older, a whole number of
    # batches of two, so four are shed.
    assert Enum.map(carrying, & &1.payload["call_id"]) == ["c5", "c6"]

    # The transcript still has every picture; only the request leaves them out.
    assert length(Enum.filter(tool_results(session), &Map.has_key?(&1.payload, "attachments"))) ==
             6
  end

  test "keep_media and input_modalities are checked when the session starts", context do
    Process.flag(:trap_exit, true)

    assert {:error, _reason} =
             Lemieux.start_session(
               supervisor: context.runtime,
               provider: Scripted.new([]),
               store: context.store,
               model: "test:model",
               keep_media: -1
             )

    assert {:error, _reason} =
             Lemieux.start_session(
               supervisor: context.runtime,
               provider: Scripted.new([]),
               store: context.store,
               model: "test:model",
               input_modalities: "image"
             )
  end

  test "an attachment's shape is the one a prompt's @ attachment has" do
    assert Attachment.valid?(Attachment.new(:image, "image/png", @png))
  end
end
