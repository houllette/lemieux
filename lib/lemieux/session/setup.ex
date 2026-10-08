defmodule Lemieux.Session.Setup do
  @moduledoc false

  alias Lemieux.Clock
  alias Lemieux.Compaction
  alias Lemieux.Evidence.ArtifactReference
  alias Lemieux.Harness.Validation
  alias Lemieux.Messages
  alias Lemieux.Session.Catalog
  alias Lemieux.Session.Core
  alias Lemieux.Session.Guard
  alias Lemieux.Session.ToolWave
  alias Lemieux.Store
  alias Lemieux.Tool
  alias Lemieux.Tool.Profile
  alias Lemieux.Tool.Receipt
  alias Lemieux.Tools
  alias Lemieux.Transcript

  # Stubbing old tool output; `Lemieux.Compaction.applied/2` says what each is.
  @stub_keep 40
  @stub_batch 20
  @stub_min_bytes 4_096

  # The same for images and documents tools returned — screenshots, mostly,
  # which a browser session produces one of per step. Also the batch they are
  # shed in, so the cached prefix changes once per this many new ones.
  @keep_media 4

  # Long enough that a person can look at an approval and decide, short enough
  # that an unattended session ends rather than waiting forever. The failure
  # being avoided is a stuck process that looks like a working agent.
  @approval_timeout :timer.minutes(5)

  # A session's configuration, declared once, because it lives in three places
  # that have to agree: what the transcript records, what a resume restores, and
  # what a command passes. Missing the third is how a session deliberately given
  # fewer tools got them all back by being resumed.
  #
  # `:cwd` is recorded and deliberately not restored — location is not behaviour.
  # Identity is not here at all: adding `root_session_id` once made every fork
  # record a new configuration entry, because a fork's root really is different
  # from its source's. `Lemieux.Transcript.delegated?/2` answers that question
  # instead.
  @restored ~w(model system tools disabled_tools mcp_servers params reasoning_effort)a
  @recorded_only ~w(cwd tool_profile harness_assembly)a
  @configuration @restored ++ @recorded_only
  @recordable_params ~w(temperature max_tokens top_p top_k seed stop frequency_penalty presence_penalty)a

  # A store that cannot lock claims nothing; one whose claim is held by another
  # live writer is the one refusal worth a sentence of its own, because the fix
  # is somebody else's terminal.
  def claim_transcript(opts) do
    if Keyword.get(opts, :transcript_lock, true) do
      case Store.lock(Keyword.fetch!(opts, :store), Keyword.fetch!(opts, :id)) do
        {:ok, lock} -> {:ok, lock}
        {:error, {:locked, holder}} -> {:error, {:session_locked, lock_holder(holder)}}
        {:error, reason} -> {:error, {:session_lock_failed, reason}}
      end
    else
      {:ok, nil}
    end
  end

  def mcp_grace_deadline(_clock, :infinity), do: :infinity

  def mcp_grace_deadline(clock, ms) when is_integer(ms) and ms >= 0,
    do: Clock.now_ms(clock) + ms

  def mcp_grace_deadline(_clock, invalid),
    do:
      raise(
        ArgumentError,
        ":mcp_grace_ms must be a non-negative integer or :infinity, got: #{inspect(invalid)}"
      )

  # Once per model: a status line that learns the window is unknown from every
  # request has nothing new to say after the first.
  def notice_unknown_window(%{context_window: nil, window_notice: model, model: model} = state),
    do: state

  def notice_unknown_window(%{context_window: nil} = state) do
    Core.emit(
      %{state | window_notice: state.model},
      {:context_window_unknown, %{model: state.model, fallback: state.context_window_fallback}}
    )
  end

  def notice_unknown_window(state), do: state

  # A transcript left inside a tool wave carries calls nothing answered, and a
  # provider refuses an assistant turn whose calls are not all answered. Answering
  # them as unknown is what makes such a transcript resumable; the text
  # `Lemieux.Tool.Receipt` writes is what keeps the model from repeating a call
  # whose effect may already have happened.
  def answer_lost_calls(state) do
    state
    |> Core.entries()
    |> Transcript.unanswered_calls()
    |> Enum.reduce(state, fn call, state ->
      result =
        Receipt.lost(
          call,
          ToolWave.call_descriptor(state, call),
          nil,
          :session_ended,
          Messages.render(state.messages, :lost_call, [call])
        )

      Core.append(state, {:tool_result, ToolWave.payload(result), nil})
    end)
  end

  # Only when it differs from what the transcript already says. Shared by
  # startup and live reconfiguration so both leave the same event-sourced
  # account of what future turns will use.
  def record_config(state) do
    config = config(state)

    if config == state.recorded_config do
      state
    else
      %{state | recorded_config: config} |> Core.append({:session, config, nil})
    end
  end

  def merge_mcp_servers(incoming, existing) do
    servers = existing ++ incoming
    order = servers |> Enum.map(&Map.fetch!(&1, "name")) |> Enum.uniq()
    latest = Map.new(servers, &{Map.fetch!(&1, "name"), &1})

    Enum.map(order, &Map.fetch!(latest, &1))
  end

  # Counted from when this process starts, on the session's clock, so a
  # resumed session's time is the host's new allowance rather than whatever
  # was left of an old one.
  def deadline_at(clock, ms) when is_integer(ms) and ms > 0, do: Clock.now_ms(clock) + ms
  def deadline_at(_clock, _ms), do: nil

  def optional_positive_option(opts, key) do
    if is_nil(opts[key]), do: nil, else: positive_option(opts, key, nil)
  end

  def max_cost_usd(opts) do
    case Keyword.get(opts, :max_cost_usd) do
      nil ->
        nil

      cap when is_number(cap) and cap >= 0 ->
        cap

      invalid ->
        raise ArgumentError,
              ":max_cost_usd must be a non-negative number, got: #{inspect(invalid)}"
    end
  end

  def messages_option(opts) do
    case Keyword.get(opts, :messages, Messages) do
      module when is_atom(module) and not is_nil(module) ->
        Messages.validate!(module)

      invalid ->
        raise ArgumentError,
              ":messages must be a module implementing Lemieux.Messages, got: #{inspect(invalid)}"
    end
  end

  # Normalised to the pair once, the way `:store` arrives, so every dispatch
  # through the seam is one shape.
  def compaction_option(opts),
    do: Validation.strategy!(Keyword.get(opts, :compaction, Compaction), :compaction, Compaction)

  def guard_option(opts),
    do: Validation.strategy!(Keyword.get(opts, :guard, Guard), :guard, Guard)

  def boolean_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) -> value
      invalid -> raise ArgumentError, ":#{key} must be a boolean, got: #{inspect(invalid)}"
    end
  end

  def stub_option(opts) do
    case Keyword.get(opts, :stub_tool_results, []) do
      false ->
        nil

      options when is_list(options) ->
        Keyword.merge([keep: @stub_keep, batch: @stub_batch, min_bytes: @stub_min_bytes], options)

      invalid ->
        raise ArgumentError,
              ":stub_tool_results must be a keyword list or false, got: #{inspect(invalid)}"
    end
  end

  def keep_media_option(opts) do
    case Keyword.get(opts, :keep_media, @keep_media) do
      :all ->
        :all

      keep when is_integer(keep) and keep >= 0 ->
        keep

      invalid ->
        raise ArgumentError,
              ":keep_media must be a non-negative integer or :all, got: #{inspect(invalid)}"
    end
  end

  def modalities_option(opts) do
    case Keyword.get(opts, :input_modalities) do
      nil ->
        nil

      modalities when is_list(modalities) ->
        if Enum.all?(modalities, &is_atom/1),
          do: modalities,
          else: raise(ArgumentError, ":input_modalities must be a list of atoms")

      invalid ->
        raise ArgumentError,
              ":input_modalities must be a list of atoms, got: #{inspect(invalid)}"
    end
  end

  def approval_timeout_option(opts) do
    case Keyword.get(opts, :approval_timeout, @approval_timeout) do
      :infinity ->
        :infinity

      ms when is_integer(ms) and ms > 0 ->
        ms

      invalid ->
        raise ArgumentError,
              ":approval_timeout must be a positive integer or :infinity, got: #{inspect(invalid)}"
    end
  end

  def positive_option(opts, key, default) do
    case Keyword.get(opts, key, default) do
      value when is_integer(value) and value > 0 ->
        value

      invalid ->
        raise ArgumentError, ":#{key} must be a positive integer, got: #{inspect(invalid)}"
    end
  end

  def validate_evidence_artifacts(artifacts) when is_list(artifacts) do
    Enum.reduce_while(artifacts, {:ok, []}, fn artifact, {:ok, validated} ->
      case evidence_artifact(artifact) do
        {:ok, reference} -> {:cont, {:ok, [reference | validated]}}
        {:error, reason} -> {:halt, {:error, {:invalid_evidence_artifact, reason}}}
      end
    end)
    |> case do
      {:ok, reversed} -> {:ok, Enum.reverse(reversed)}
      {:error, reason} -> {:error, reason}
    end
  end

  def validate_evidence_artifacts(_artifacts), do: {:error, :invalid_evidence_artifacts}

  defp evidence_artifact(%ArtifactReference{} = reference), do: {:ok, reference}

  defp evidence_artifact(reference) when is_map(reference),
    do: ArtifactReference.from_map(reference)

  defp evidence_artifact(_reference), do: {:error, :invalid_artifact_reference}

  defp config(state) do
    @configuration
    |> Map.new(&{Atom.to_string(&1), record(state, &1)})
    |> Enum.reject(fn {key, value} -> key == "harness_assembly" and is_nil(value) end)
    |> Map.new()
  end

  # Tool calls from earlier turns remain in the provider conversation. Merely
  # replacing the request's catalog leaves a model free to infer that an old
  # name is still callable. This system entry makes the new boundary explicit
  # and is replayed on resume like the calls whose availability it corrects.
  def tool_profile_notice(state, tools) do
    names = Enum.map(tools, &Tool.name/1)
    {:system, %{"text" => Messages.render(state.messages, :tools_changed, [names])}, nil}
  end

  # One clause per declared key. A key added to @configuration without one
  # fails here, loudly, the first time any session starts.
  defp record(state, :model), do: state.model
  defp record(state, :system), do: state.system
  defp record(state, :params), do: recordable_params(state.params)
  defp record(state, :reasoning_effort), do: Catalog.reasoning_effort(state)
  # Only the first-party ones: a remote tool is not configuration, it is
  # something a configured server happened to offer, and recording it would
  # produce a transcript that tries to restore tools by name from a server
  # that may no longer offer them.
  defp record(state, :tools),
    do:
      state.tool_profile
      |> Profile.filter(state.configured_tools)
      |> Enum.filter(&is_atom/1)
      |> Enum.map(&Atom.to_string/1)

  defp record(state, :disabled_tools),
    do: state.disabled_tools |> MapSet.to_list() |> Enum.sort()

  defp record(state, :mcp_servers), do: state.mcp_servers
  defp record(state, :cwd), do: state.cwd
  defp record(state, :tool_profile), do: Profile.snapshot(state.tool_profile)
  # Inert host assembly notes, deliberately not restored by the loop. The
  # resuming host decides which code and authority may reconstruct the tools.
  defp record(state, :harness_assembly), do: state.evidence.harness_context["assembly"]

  def recorded_config(entries) do
    entries
    |> Enum.filter(&(&1.type == :session))
    |> List.last()
    |> config_payload()
    |> with_configuration_defaults()
  end

  defp config_payload(nil), do: nil
  defp config_payload(entry), do: entry.payload

  defp with_configuration_defaults(nil), do: nil

  defp with_configuration_defaults(config) do
    config
    |> Map.put_new("params", %{})
    |> Map.put_new("disabled_tools", [])
    |> Map.put_new("tool_profile", Profile.snapshot(Profile.new(nil)))
  end

  # A session is resumed as it was, not as the caller's defaults would have
  # it: an option that was not passed comes from the transcript. Restoring the
  # tool set is the one with teeth — a session deliberately started with fewer
  # tools must not get them back by being resumed.
  def resolve(opts, key, recorded, recorded_key, default) do
    cond do
      Keyword.has_key?(opts, key) ->
        Keyword.fetch!(opts, key)

      is_map(recorded) and is_map_key(recorded, recorded_key) ->
        Map.fetch!(recorded, recorded_key)

      is_function(default) ->
        default.()

      true ->
        raise ArgumentError, "a session needs a #{key}"
    end
  end

  def resolve_tools(opts, recorded) do
    case resolve(opts, :tools, recorded, "tools", &Tools.default/0) do
      tools when is_list(tools) -> Enum.map(tools, &tool_module/1)
    end
  end

  def resolve_disabled_tools(opts, recorded) do
    opts
    |> resolve(:disabled_tools, recorded, "disabled_tools", fn -> [] end)
    |> MapSet.new()
  end

  def resolve_tool_profile(opts, recorded) do
    cond do
      Keyword.has_key?(opts, :tool_profile) ->
        opts |> Keyword.fetch!(:tool_profile) |> Profile.new()

      recorded_profile_requires_authorization?(recorded) ->
        raise ArgumentError,
              "resuming a session with a recorded host tool profile requires the current " <>
                "host to pass :tool_profile again"

      true ->
        Profile.new(nil)
    end
  end

  defp recorded_profile_requires_authorization?(%{
         "tool_profile" => %{"id" => id}
       })
       when id != "legacy",
       do: true

  defp recorded_profile_requires_authorization?(_recorded), do: false

  def resolve_params(opts, recorded) do
    params = Keyword.merge(restored_params(recorded), Keyword.get(opts, :params, []))

    effort =
      cond do
        Keyword.has_key?(opts, :reasoning_effort) ->
          Catalog.normalize_effort(Keyword.fetch!(opts, :reasoning_effort))

        Keyword.has_key?(params, :reasoning_effort) ->
          Catalog.normalize_effort(Keyword.fetch!(params, :reasoning_effort))

        is_map(recorded) and is_map_key(recorded, "reasoning_effort") ->
          Catalog.normalize_effort(Map.fetch!(recorded, "reasoning_effort"))

        true ->
          nil
      end

    Catalog.put_reasoning_effort(params, effort)
  end

  defp restored_params(%{"params" => params}) when is_map(params) do
    Enum.flat_map(@recordable_params, fn key ->
      case Map.fetch(params, Atom.to_string(key)) do
        {:ok, value} -> [{key, value}]
        :error -> []
      end
    end)
  end

  defp restored_params(_recorded), do: []

  defp recordable_params(params) do
    params
    |> Keyword.take(@recordable_params)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), json_param(value)} end)
  end

  defp json_param(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json_param(value) when is_atom(value), do: Atom.to_string(value)
  defp json_param(value) when is_list(value), do: Enum.map(value, &json_param/1)
  defp json_param(value) when is_map(value), do: Map.new(value, &json_param_pair/1)
  defp json_param(_value), do: "[not serializable]"

  defp json_param_pair({key, value}), do: {to_string(key), json_param(value)}

  defp tool_module(module) when is_atom(module), do: module
  defp tool_module(%module{} = tool) when is_atom(module), do: tool

  defp tool_module(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError ->
      reraise ArgumentError,
              [
                message:
                  "the transcript names a tool this build does not have: #{name}. " <>
                    "Pass :tools explicitly to resume without it."
              ],
              __STACKTRACE__
  end

  # The store describes the holder in its own JSON — string keys, from the
  # lock file. Callers get the documented shape with atom keys, which is what
  # every host wording a refusal reads; a host reading string keys got a
  # message with no pid, host, time or path in it.
  defp lock_holder(holder) when is_map(holder) do
    %{
      host: holder["host"],
      os_pid: holder["os_pid"],
      process: holder["process"],
      since: holder["since"],
      path: holder["path"]
    }
  end
end
