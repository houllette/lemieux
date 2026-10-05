defmodule Lemieux.RequestSnapshot do
  @moduledoc """
  A durable, provider-neutral account of one model request.

  Provider HTTP bodies are deliberately not stored: they may contain
  credentials, provider-specific defaults, and wire formats owned by
  `req_llm`. This snapshot records the canonical input Lemieux handed to that
  seam — resolved system text, exact transcript entry ids, full tool schemas,
  safe generation parameters, versions, and a digest. It is enough to audit
  semantic drift and rebuild the historical request with compatible tools,
  without claiming that a future dependency version will emit byte-identical
  HTTP.
  """

  alias Lemieux.Request
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor

  @version 1
  @redacted ~w(api_key authorization base_url headers http_options plug transport_options)

  @doc "Builds the JSON-shaped payload persisted as a `:request` entry."
  @spec build(Request.t(), keyword()) :: map()
  def build(%Request{} = request, opts \\ []) do
    tools = Enum.map(request.tools, &model_descriptor/1)
    catalog = catalog(request, tools, opts)

    payload = %{
      "schema_version" => @version,
      "id" => Keyword.get_lazy(opts, :id, &Lemieux.ID.generate/0),
      "kind" => opts |> Keyword.get(:kind, :turn) |> to_string(),
      "model" => request.model,
      "system" => request.system,
      "system_sha256" => digest(request.system || ""),
      "system_bytes" => byte_size(request.system || ""),
      "input_bytes" => Request.input_bytes(request),
      "entry_ids" => request.entries |> Enum.filter(&conversation_entry?/1) |> Enum.map(& &1.id),
      "tools" => tools,
      "catalog" => catalog,
      "params" => safe_params(request.params),
      "output_schema" => json(request.output_schema),
      "lemieux_version" => Lemieux.version(),
      "req_llm_version" => dependency_version(:req_llm),
      "harness_snapshot_id" => Keyword.get(opts, :harness_snapshot_id),
      "harness_snapshot_sha256" => Keyword.get(opts, :harness_snapshot_sha256)
    }

    # Only a request that *is* a retry says so, so every other snapshot keeps
    # the digest it had before the field existed. The record is here rather
    # than in an error entry because an error entry means the turn ended,
    # and a retried failure is one the turn survived.
    payload =
      case Keyword.get(opts, :retry) do
        %{} = retry -> Map.put(payload, "retry", retry)
        _none -> payload
      end

    payload = at_level(payload, Keyword.get(opts, :evidence, :full))

    Map.put(payload, "sha256", payload |> Map.delete("id") |> JSON.encode!() |> digest())
  end

  # How much of the request is written. `:full` is the whole account.
  # `:digests` keeps what identifies and measures a request — its digests,
  # sizes, entry ids and parameters — and drops the prompt text and schemas,
  # for a host that wants resume and accounting without the audit copy; the
  # snapshot's own digest is over what is kept, so it still verifies.
  defp at_level(payload, :full), do: payload

  defp at_level(payload, level) when level in [:digests, :off] do
    payload
    |> Map.put("evidence", "digests")
    |> Map.put("system", nil)
    |> Map.update!("tools", fn tools -> Enum.map(tools, &Map.take(&1, ["name"])) end)
    |> Map.update!("catalog", &identified_catalog/1)
  end

  # A catalog at `:digests`: whether each tool was offered, and which
  # descriptor, not the descriptor's schema.
  defp identified_catalog(catalog),
    do: Map.update!(catalog, "tools", fn tools -> Enum.map(tools, &identified/1) end)

  defp identified(tool),
    do: Map.update!(tool, "descriptor", &Map.take(&1, ["identity", "digest"]))

  @doc "Returns a snapshot's stable request identifier."
  @spec id(map()) :: String.t()
  def id(%{"id" => id}), do: id

  @doc "Verifies that a durable snapshot still matches its canonical digest."
  @spec verify(map()) :: :ok | {:error, :digest_mismatch | :missing_digest}
  def verify(%{"sha256" => expected} = payload) when is_binary(expected) do
    actual = payload |> Map.drop(["id", "sha256"]) |> JSON.encode!() |> digest()
    if actual == expected, do: :ok, else: {:error, :digest_mismatch}
  end

  def verify(_payload), do: {:error, :missing_digest}

  defp model_descriptor(tool) do
    %{
      "name" => Tool.name(tool),
      "description" => Tool.description(tool),
      "schema" => Tool.schema(tool)
    }
  end

  defp catalog(request, model_tools, opts) do
    serialized = JSON.encode!(model_tools)
    visible = MapSet.new(request.tools, &Tool.name/1)

    tools =
      opts
      |> Keyword.get(:catalog, request.tools)
      |> merge_catalog(request.tools)
      |> Enum.map(fn tool ->
        enabled? = MapSet.member?(visible, Tool.name(tool))

        %{
          "enabled" => enabled?,
          "disabled_reason" => if(enabled?, do: nil, else: "profile_or_session"),
          "descriptor" => tool |> Tool.descriptor() |> Descriptor.to_map()
        }
      end)

    {tokenizer, token_count} = token_measurement(opts[:token_counter], request.model, serialized)

    # The serialized schemas are measured and digested but not stored: they are
    # `JSON.encode!(payload["tools"])`, which the snapshot already holds, and
    # storing the string beside the list and the descriptors wrote every tool
    # schema three times per request.
    %{
      "model" => request.model,
      "profile" => json(Keyword.get(opts, :tool_profile)),
      "bytes" => byte_size(serialized),
      "sha256" => digest(serialized),
      "tokenizer" => tokenizer,
      "token_count" => token_count,
      "tools" => tools
    }
  end

  defp merge_catalog(catalog, request_tools) do
    (catalog ++ request_tools)
    |> Enum.reduce({MapSet.new(), []}, fn tool, {seen, reversed} ->
      name = Tool.name(tool)

      if MapSet.member?(seen, name),
        do: {seen, reversed},
        else: {MapSet.put(seen, name), [tool | reversed]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp token_measurement(counter, model, serialized) when is_function(counter, 2) do
    case counter.(model, serialized) do
      {:ok, tokenizer, count}
      when is_binary(tokenizer) and is_integer(count) and count >= 0 ->
        {tokenizer, count}

      _unknown ->
        {nil, nil}
    end
  rescue
    _error -> {nil, nil}
  catch
    _kind, _reason -> {nil, nil}
  end

  defp token_measurement(_counter, _model, _serialized), do: {nil, nil}

  defp conversation_entry?(%{type: type}) when type in [:user, :system, :assistant, :tool_result],
    do: true

  defp conversation_entry?(_entry), do: false

  defp safe_params(params) do
    Map.new(params, fn {key, value} -> {to_string(key), safe_value(key, value)} end)
  end

  defp safe_value(key, value) do
    if to_string(key) in @redacted, do: "[redacted]", else: json(value)
  end

  defp json(value)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp json(value) when is_atom(value), do: Atom.to_string(value)

  defp json(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {to_string(key), json(item)} end)

  defp json(value) when is_list(value), do: Enum.map(value, &json/1)
  defp json(value) when is_tuple(value), do: value |> Tuple.to_list() |> Enum.map(&json/1)

  defp json(_value), do: "[not serializable]"

  defp dependency_version(app) do
    case Application.spec(app, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
