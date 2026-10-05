defmodule Lemieux.Tools do
  @moduledoc """
  Running one tool call, hooks and all.

  Every tool call in lemieux goes through `run/4` — the first-party four, and
  (from Phase 6) anything an MCP server offers. That is deliberate: policy,
  the transcript's record of what actually ran, and the promise that a failure
  reaches the model rather than the loop are all properties of *this function*,
  and a second path that skipped it would quietly have none of them.

  ## Everything comes back as a result

  `run/4` does not raise and does not return `{:error, _}` in the loop's sense.
  Its answer is always a result the model can read: the output, or the reason
  there is not one — an unknown tool name, a denial from a hook, a file that
  is not there, a command that exited non-zero. The loop's job is then the
  same in every case, which is why there is no case in the loop.

  The one thing that does not come back through here is a tool that crashes
  the process running it. That is handled by `Lemieux.Session`, which turns
  the exit into the same shape.
  """

  alias Lemieux.Hooks
  alias Lemieux.Provider
  alias Lemieux.Provider.Error, as: ProviderError
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tool.Result
  alias Lemieux.Tools.Bash
  alias Lemieux.Tools.Edit
  alias Lemieux.Tools.Read
  alias Lemieux.Tools.Write

  @default [Read, Write, Edit, Bash]

  @typedoc """
  One call's outcome, in the shape a `:tool_result` entry is built from.

  `arguments` is what actually ran, which is not always what the model asked
  for — a hook may have rewritten it. Recording the effective arguments next
  to the output they produced is what stops the two from drifting apart.
  """
  @type result :: %{
          optional(:duration_ms) => non_neg_integer(),
          optional(:descriptor_digest) => String.t() | nil,
          optional(:tool_identity) => map() | nil,
          optional(:structured_content) => term() | nil,
          optional(:content) => [map()],
          optional(:artifacts) => [map()],
          optional(:attachments) => [Lemieux.Tool.Attachment.t()],
          optional(:cost) => map() | nil,
          optional(:metadata) => map(),
          optional(:hook_rewritten?) => boolean(),
          optional(:receipt) => map(),
          call_id: String.t(),
          name: String.t(),
          arguments: map(),
          output: String.t(),
          error?: boolean(),
          outcome: atom(),
          output_bytes: non_neg_integer()
        }

  @doc """
  The tools a session gets when it is not told otherwise.
  """
  @spec default() :: [Tool.t()]
  def default, do: @default

  @doc """
  The default tools, less the ones named in `except:`.

  A host that wants the defaults without `write` should not have to know the
  other three by module and rebuild the list: that copy is the one that falls
  behind when the defaults change. Names are the model-facing names. One that
  is not a default raises, because `except: ["wrte"]` quietly keeping `write`
  is the mistake this function exists to prevent.
  """
  @spec default(opts :: [except: [String.t()]]) :: [Tool.t()]
  def default(opts) when is_list(opts) do
    :ok = known_default_options(opts)
    except = Keyword.get(opts, :except, [])
    names = Enum.map(@default, &Tool.name/1)
    :ok = known_default_names(except, names)
    Enum.reject(@default, &(Tool.name(&1) in except))
  end

  defp known_default_options(opts) do
    case Keyword.keys(opts) -- [:except] do
      [] ->
        :ok

      unknown ->
        raise ArgumentError, "Lemieux.Tools.default/1 takes :except only; got #{inspect(unknown)}"
    end
  end

  defp known_default_names(except, names) when is_list(except) do
    case Enum.reject(except, &(is_binary(&1) and &1 in names)) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "not default tools: #{inspect(unknown)}; the defaults are #{Enum.join(names, ", ")}"
    end
  end

  defp known_default_names(except, _names) do
    raise ArgumentError, "except: takes a list of tool names; got #{inspect(except)}"
  end

  @doc """
  Runs one call: hooks, then the tool, then hooks.
  """
  @spec run(
          tools :: [Tool.t()],
          hooks :: Hooks.t(),
          call :: Provider.tool_call(),
          context :: Tool.context()
        ) :: result()
  def run(tools, hooks, call, context), do: run(tools, hooks, call, context, fn _ -> :ok end)

  @doc "Runs one call and forwards streamed output chunks."
  @spec run(
          tools :: [Tool.t()],
          hooks :: Hooks.t(),
          call :: Provider.tool_call(),
          context :: Tool.context(),
          emit :: (String.t() -> any())
        ) :: result()
  def run(_tools, _hooks, %{argument_error: reason} = call, _context, _emit) do
    error(
      call,
      "invalid tool arguments: #{ProviderError.message(reason)}. Send one JSON object that matches the tool schema.",
      :invalid_arguments
    )
  end

  def run(tools, hooks, call, context, emit) do
    # A composed tool must inherit the effective host policy, including final
    # session overrides. Capturing hooks at extension assembly time silently
    # bypasses a later denial on the tool's nested calls. This executable state
    # belongs only in the invocation context, never in result evidence.
    context = Map.put(context, :hooks, hooks)

    with {:ok, tool} <- fetch(tools, call.name),
         descriptor = Tool.descriptor(tool),
         context = Map.put(context, :tool_descriptor, Descriptor.to_map(descriptor)),
         {:ok, args} <- Hooks.before_tool_call(hooks, call, context) do
      limit = Descriptor.output_limit(descriptor, Map.fetch!(context, :tool_output_bytes))
      result = descriptor |> Tool.invoke(args, context) |> Tool.collect_result(emit, limit)
      # A post-tool hook cannot undo the call, but it can tell the model about
      # it — a formatter's complaint, a policy's objection — and that only
      # counts if it reaches the result the model reads next.
      feedback =
        Hooks.after_tool_call_feedback(
          hooks,
          %{call | arguments: args},
          hook_result(result),
          context
        )

      finish(call, args, descriptor, Hooks.append_feedback(result, feedback))
    else
      {:error, message} -> error(call, message, :unavailable)
      {:deny, reason} -> error(call, "denied: #{reason}", :denied)
    end
  end

  defp fetch(tools, name) do
    case Tool.fetch(tools, name) do
      {:ok, tool} ->
        {:ok, tool}

      :error ->
        {:error,
         "tool #{inspect(name)} is not available in the current tool profile. " <>
           "Available tools: #{names(tools)}. Use one of those instead."}
    end
  end

  defp names([]), do: "none"
  defp names(tools), do: Enum.map_join(tools, ", ", &Tool.name/1)

  defp finish(call, args, descriptor, {:ok, %Result{} = result}) do
    result_fields(call, args, descriptor, result, false, :success)
  end

  defp finish(call, args, descriptor, {:error, %Result{} = result}) do
    result_fields(call, args, descriptor, result, true, :error)
  end

  defp result_fields(call, args, descriptor, result, error?, outcome) do
    base = %{
      call_id: call.id,
      name: call.name,
      arguments: args,
      hook_rewritten?: args != Map.get(call, :arguments, %{}),
      output: result.model_text,
      error?: error?,
      outcome: outcome,
      descriptor_digest: descriptor.digest,
      tool_identity: descriptor.identity,
      output_bytes: byte_size(result.model_text)
    }

    keys = %{
      "structured_content" => :structured_content,
      "content" => :content,
      "artifacts" => :artifacts,
      "cost" => :cost,
      "metadata" => :metadata
    }

    fields =
      Enum.reduce(Result.to_map(result), base, fn {key, value}, result ->
        Map.put(result, Map.fetch!(keys, key), value)
      end)

    # Outside `to_map/1` on purpose: attachments are what the model is shown,
    # not audit evidence, and are bounded by their own limits.
    case result.attachments do
      [] -> fields
      attachments -> Map.put(fields, :attachments, attachments)
    end
  end

  defp hook_result({:ok, %Result{} = result}), do: {:ok, result.model_text}
  defp hook_result({:error, %Result{} = result}), do: {:error, result.model_text}

  defp error(call, message, outcome) do
    %{
      call_id: call.id,
      name: call.name,
      arguments: Map.get(call, :arguments, %{}),
      output: to_string(message),
      error?: true,
      outcome: outcome,
      descriptor_digest: nil,
      tool_identity: nil,
      output_bytes: message |> to_string() |> byte_size()
    }
  end
end
