defmodule Lemieux.Tool.Receipt do
  @moduledoc """
  What the model is told when a tool's outcome was lost, and how a tool can
  leave a receipt behind before it is.

  Every call gets a result, and until now a call whose task crashed, ran out
  of clock or was cancelled got one that read as a failure: `the tool
  crashed`, `outcome: :crashed`. For `read`, `edit` and `bash` that is the
  truth the model needs — the workspace is right there to inspect, and a
  crashed `bash` is safe to run again. It is the wrong truth for a tool whose
  effect is somewhere else. A `send_email` that crashed *after* the provider
  accepted the message has succeeded; a result that calls it a failure sends
  a model that trusts its tools straight into sending it twice. Legion's
  action receipts are the prior art, and this is the smallest version of them
  that fits an append-only transcript.

  ## Two halves

  **Unknown is an outcome.** A tool declares that its effects cannot be
  inspected or safely repeated — `Lemieux.Tool.Descriptor.receipt?/1` says
  how, and every MCP tool is taken to have declared it — and a lost result
  for such a tool is written with `outcome: :unknown` and text that says the
  effect may have happened and must be checked before the call is repeated.
  A result lost because the *session* ended is unknown for every tool, since
  nothing at all is known about it; that is what makes a transcript left
  inside a tool wave resumable, because a provider refuses an assistant turn
  whose calls are not all answered.

  **A receipt survives the call.** A tool that has just been told by the
  remote side what it did — a message id, a ticket key, an order number —
  calls `record/2` from inside `run/2`, and the session keeps that map for
  as long as the call runs. If the call then completes, the receipt travels
  with its result; if the call is lost, the receipt travels with the unknown
  outcome, so the model can reconcile against it rather than guess. A tool
  that records a receipt has said its effect is committed, so its lost result
  is unknown whatever its descriptor says.

  ## What is written

  The `:tool_result` entry carries `"receipt"` when either half applies:
  `"reported"` is the map the tool recorded, and `"lost"` is why the outcome
  is unknown — `"crashed"`, `"timeout"`, `"cancelled"` or `"session_ended"`.
  A completed call that recorded nothing carries no `"receipt"` key at all,
  which keeps the common case the shape it was.

  What this does not do is make a tool idempotent or retry it. It changes
  what the model is told, and a model told the truth about an unknown
  outcome is the whole mechanism.
  """

  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor

  @typedoc "Why a result was lost."
  @type loss :: :crashed | :timeout | :cancelled | :session_ended

  @doc """
  Leaves a receipt with the session from inside a running tool call.

  Call it the moment the remote side has acknowledged the effect and before
  doing anything else that could fail. `receipt` must be a JSON-shaped map:
  it is written into the transcript, and a value the transcript cannot hold
  is refused here rather than crashing the session's write. Sending is
  asynchronous; the receipt is ordered before the tool's own return because
  both come from the task running it.

  A receipt for a call the session is no longer running is dropped, the way
  a late output chunk is.
  """
  @spec record(context :: Tool.context(), receipt :: map()) :: :ok | {:error, :not_json}
  def record(%{session: session, call_id: call_id}, receipt)
      when is_pid(session) and is_binary(call_id) and is_map(receipt) do
    if json?(receipt) do
      send(session, {:tool_receipt, call_id, receipt})
      :ok
    else
      {:error, :not_json}
    end
  end

  @doc """
  The result for a call whose outcome was lost.

  `happened` is the sentence saying what the harness saw — the crash, the
  deadline, the cancellation, the session ending. Whether the outcome is
  then `:unknown` or simply the loss itself depends on what is known about
  the tool: a declared external effect, a recorded receipt, or a session
  that ended all make it unknown, and the text tells the model what to do
  about that. Anything else keeps the loss as its outcome — a crashed `read`
  is a crashed `read`, and the model can look.
  """
  @spec lost(
          call :: map(),
          descriptor :: Descriptor.t() | nil,
          reported :: map() | nil,
          loss :: loss(),
          happened :: String.t()
        ) :: Lemieux.Tools.result()
  def lost(call, descriptor, reported, loss, happened)
      when loss in [:crashed, :timeout, :cancelled, :session_ended] and is_binary(happened) do
    unknown? = unknown?(descriptor, reported, loss)
    output = if unknown?, do: happened <> consequence(descriptor, reported, loss), else: happened

    %{
      call_id: call.id,
      name: call.name,
      arguments: Map.get(call, :arguments, %{}),
      output: output,
      error?: true,
      outcome: if(unknown?, do: :unknown, else: loss),
      descriptor_digest: descriptor && descriptor.digest,
      tool_identity: descriptor && descriptor.identity,
      output_bytes: byte_size(output),
      duration_ms: 0
    }
    |> with_receipt(reported, unknown? and loss)
  end

  @doc "Attaches a recorded receipt to the result of a call that completed."
  @spec reported(result :: map(), reported :: map() | nil) :: map()
  def reported(result, nil), do: result
  def reported(result, receipt) when is_map(receipt), do: with_receipt(result, receipt, false)

  defp unknown?(_descriptor, _reported, :session_ended), do: true
  defp unknown?(_descriptor, reported, _loss) when is_map(reported), do: true
  defp unknown?(nil, _reported, _loss), do: false
  defp unknown?(descriptor, _reported, _loss), do: Descriptor.receipt?(descriptor)

  # What the model should make of an unknown outcome, in the order it needs
  # it: whether the effect may have happened, and what it has to go on.
  defp consequence(descriptor, reported, loss) do
    external? = is_map(reported) or (descriptor != nil and Descriptor.receipt?(descriptor))

    effect =
      cond do
        external? ->
          " Its effects are external and may have happened; check before repeating the call."

        loss == :session_ended ->
          " It may or may not have run; check before repeating it."

        true ->
          ""
      end

    case reported do
      nil ->
        effect

      receipt ->
        effect <> " It reported this receipt before it was lost: #{JSON.encode!(receipt)}."
    end
  end

  defp with_receipt(result, nil, false), do: result

  defp with_receipt(result, reported, lost) do
    receipt =
      %{}
      |> put_present("reported", reported)
      |> put_present("lost", lost && Atom.to_string(lost))

    Map.put(result, :receipt, receipt)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, false), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  defp json?(value) when is_binary(value) or is_number(value) or is_boolean(value), do: true
  defp json?(nil), do: true
  defp json?(value) when is_list(value), do: Enum.all?(value, &json?/1)

  defp json?(value) when is_map(value) do
    Enum.all?(value, fn {key, nested} -> is_binary(key) and json?(nested) end)
  end

  defp json?(_value), do: false
end
