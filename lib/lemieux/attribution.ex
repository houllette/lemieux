defmodule Lemieux.Attribution.Feedback do
  @moduledoc """
  Typed extension feedback with declared source and category.

  Construct through `Lemieux.Attribution.notice/4` or `Lemieux.Attribution.turn/4`.
  The text enters the normal conversation; accounting retains only its byte
  count, category and source. The source label grants no identity or authority.
  Inspection omits text so diagnostics do not accidentally repeat feedback.
  """
  @derive {Inspect, except: [:text]}
  @enforce_keys [:source, :text, :category, :kind]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          source: String.t(),
          text: String.t(),
          category: atom(),
          kind: :notice | :turn
        }
end

defmodule Lemieux.Attribution do
  @moduledoc """
  Provider-neutral extension accounting, without inferring quality or causation.

  Catalog bytes measure the canonical JSON Lemieux describes, not a provider's
  wire body or tokenizer. Assembly ownership is bound to a descriptor digest;
  a later host replacement is unknown rather than credited to old code. Array
  delimiters are measured separately so per-tool counts reconcile exactly.

  Extensions wrap feedback with `notice/4` or `turn/4`. Metadata is committed
  only where that feedback actually enters a tool result or continuation entry,
  so canceled work and a stop denied at the turn ceiling do not invent notices.
  Counts measure feedback payload bytes, excluding shared hook delimiters.
  Source labels are declared attribution, never authenticated identity or
  authority. Existing unlabelled hooks remain explicitly unknown.

  A turn's requests inherit the most recent input's source until another input
  replaces it. Usage is joined by request id; absent/failed usage remains unknown
  or partial. This measures turns an extension started, not counterfactual work
  it caused. Hosted ablations and verifier qualification remain separate work.
  """
  alias Lemieux.Attribution.Feedback
  alias Lemieux.Entry
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Tool
  alias Lemieux.Usage
  @unknown "host_or_unknown"

  @spec notice(context :: map(), source :: module(), text :: String.t(), category :: atom()) ::
          Feedback.t()
  def notice(_context, source, text, category), do: feedback(source, text, category, :notice)

  @spec turn(context :: map(), source :: module(), text :: String.t(), category :: atom()) ::
          Feedback.t()
  def turn(_context, source, text, category), do: feedback(source, text, category, :turn)

  defp feedback(source, text, category, kind)
       when is_atom(source) and is_binary(text) and is_atom(category),
       do: %Feedback{source: inspect(source), text: text, category: category, kind: kind}

  @doc false
  @spec text(feedback :: String.t() | Feedback.t()) :: String.t()
  def text(%Feedback{text: text}), do: text
  def text(text) when is_binary(text), do: text

  @doc false
  @spec metadata(feedback :: String.t() | Feedback.t()) :: map()
  def metadata(%Feedback{} = feedback),
    do: %{
      "source" => feedback.source,
      "category" => Atom.to_string(feedback.category),
      "kind" => Atom.to_string(feedback.kind),
      "bytes" => byte_size(feedback.text)
    }

  def metadata(text) when is_binary(text),
    do: %{
      "source" => @unknown,
      "category" => "hook",
      "kind" => "notice",
      "bytes" => byte_size(text)
    }

  @doc "Record a bounded inactive reason through the existing extension-document ledger."
  @spec inactive(context :: map(), source :: module(), reason :: :no_command | :disabled) :: :ok
  def inactive(%{session: session}, source, reason) when reason in [:no_command, :disabled] do
    namespace =
      "lemieux.activity." <> String.slice(Lemieux.Contract.sha256(inspect(source)), 0, 16)

    with {:ok, %{revision: revision}} <- Session.document(session, namespace) do
      Session.put_document(session, namespace, revision, %{
        "source" => inspect(source),
        "state" => "inactive",
        "reason" => Atom.to_string(reason)
      })
    end

    :ok
  catch
    :exit, _closed -> :ok
  end

  def inactive(_context, _source, _reason), do: :ok

  @doc false
  @spec request_source(request :: Request.t()) :: String.t()
  def request_source(request), do: input_metadata(Enum.reverse(request.entries))["source"]

  @doc false
  @spec input_metadata(reversed_entries :: [Entry.t()]) :: map()
  def input_metadata(reversed_entries) do
    case Enum.find(reversed_entries, &(&1.type == :user)) do
      %Entry{payload: %{"extension_notice" => %{"kind" => "turn", "source" => source} = notice}} ->
        %{"source" => source, "category" => Map.get(notice, "category", "unknown")}

      _ordinary ->
        %{"source" => @unknown, "category" => "host_input"}
    end
  end

  @doc false
  @spec catalog(tools :: [Tool.t()], descriptors :: [map()], applied :: [map()]) :: map()
  def catalog(tools, descriptors, applied) do
    owners =
      Enum.reduce(applied, %{}, fn entry, acc ->
        Enum.reduce(Map.get(entry, "tool_ownership", []), acc, fn tool, index ->
          Map.put(index, tool["name"], {tool["digest"], entry["module"]})
        end)
      end)

    measured =
      Enum.zip_with(tools, descriptors, fn tool, descriptor ->
        digest = Tool.descriptor(tool).digest

        owner =
          case owners[Tool.name(tool)] do
            {^digest, source} -> source
            _unknown -> @unknown
          end

        %{
          "name" => Tool.name(tool),
          "bytes" => byte_size(JSON.encode!(descriptor)),
          "extension" => owner
        }
      end)

    per_extension =
      Enum.reduce(measured, %{}, fn tool, acc ->
        Map.update(acc, tool["extension"], tool["bytes"], &(&1 + tool["bytes"]))
      end)

    %{
      "per_tool" => measured,
      "per_extension" => per_extension,
      "array_overhead_bytes" => 2 + max(length(measured) - 1, 0)
    }
  end

  @doc "Aggregate committed request/catalog/notice facts for one run."
  @spec accounting(entries :: [Entry.t()], applied :: [map()]) :: map()
  def accounting(entries, applied \\ []) do
    requests = for %Entry{type: :request, payload: payload} <- entries, do: payload
    notices = Enum.flat_map(entries, &notices/1)

    responses =
      Map.new(
        Enum.flat_map(entries, fn entry ->
          id = entry.payload["request_id"] || (entry.usage && entry.usage["request_id"])

          if is_binary(id) and
               entry.type in [:assistant, :compaction, :guidance, :extension_state],
             do: [{id, reported_usage(entry.usage)}],
             else: []
        end)
      )

    initial = Map.new(applied, &{&1["module"], empty()})
    catalog = Enum.reduce(requests, initial, &add_catalog/2)

    stats =
      Enum.reduce(notices, catalog, fn notice, acc ->
        update(acc, notice["source"], fn value ->
          value
          |> update_in(["notices", "count"], &(&1 + 1))
          |> update_in(["notices", "bytes"], &(&1 + notice["bytes"]))
          |> update_in(["notices", "by_category"], &category_notice(&1, notice))
        end)
      end)

    sources = Enum.group_by(requests, &Map.get(&1, "extension_source", @unknown))

    Enum.reduce(sources, stats, fn {source, rows}, acc ->
      usages = Enum.map(rows, &Map.get(responses, &1["id"]))

      update(acc, source, fn value ->
        value
        |> Map.put("turn_requests", length(rows))
        |> Map.put("usage", usage(usages))
        |> Map.put("turns_by_category", category_turns(rows, responses))
      end)
    end)
  end

  defp category_notice(categories, notice) do
    key = notice["category"] || "unknown"

    Map.update(categories, key, %{"count" => 1, "bytes" => notice["bytes"]}, fn counts ->
      %{"count" => counts["count"] + 1, "bytes" => counts["bytes"] + notice["bytes"]}
    end)
  end

  defp category_turns(rows, responses) do
    rows
    |> Enum.group_by(&Map.get(&1, "extension_turn_category", "unknown"))
    |> Map.new(fn {category, requests} ->
      {category,
       %{
         "requests" => length(requests),
         "usage" => usage(Enum.map(requests, &Map.get(responses, &1["id"])))
       }}
    end)
  end

  @doc false
  @spec request_category(request :: Request.t()) :: String.t()
  def request_category(request), do: input_metadata(Enum.reverse(request.entries))["category"]

  defp add_catalog(request, acc) do
    Enum.reduce(get_in(request, ["catalog", "per_extension"]) || %{}, acc, fn {source, bytes},
                                                                              stats ->
      update(stats, source, fn value -> Map.update!(value, "catalog_bytes", &(&1 + bytes)) end)
    end)
  end

  @doc false
  @spec stop_payload(feedback :: String.t() | Feedback.t()) :: map()
  def stop_payload(%Feedback{} = feedback),
    do: %{"text" => feedback.text, "stop_hook" => true, "extension_notice" => metadata(feedback)}

  def stop_payload(text) when is_binary(text), do: %{"text" => text, "stop_hook" => true}

  defp reported_usage(%{"usage_reported" => false}), do: nil
  defp reported_usage(value), do: value

  defp usage(usages) do
    known = Enum.filter(usages, &is_map/1)

    state =
      cond do
        known == [] -> "unknown"
        length(known) == length(usages) -> "complete"
        true -> "partial"
      end

    %{
      "state" => state,
      "value" => if(known != [], do: known |> Usage.sum() |> Lemieux.Contract.json())
    }
  end

  defp update(stats, source, fun), do: Map.update(stats, source, fun.(empty()), fun)

  defp empty,
    do: %{
      "catalog_bytes" => 0,
      "turn_requests" => 0,
      "notices" => %{"count" => 0, "bytes" => 0, "by_category" => %{}},
      "turns_by_category" => %{},
      "usage" => %{"state" => "not_applicable", "value" => nil}
    }

  defp notices(%Entry{type: :user, payload: %{"extension_notice" => notice}}), do: [notice]

  defp notices(%Entry{type: :user, payload: %{"stop_hook" => true, "text" => text}}),
    do: [metadata(text) |> Map.put("kind", "turn")]

  defp notices(%Entry{type: :tool_result, payload: payload}),
    do: get_in(payload, ["metadata", "extension_notices"]) || []

  defp notices(_entry), do: []

  @doc false
  @spec activity(entries :: [Entry.t()]) :: map()
  def activity(entries) do
    Enum.reduce(entries, %{}, fn
      %Entry{
        type: :extension_state,
        payload: %{"namespace" => "lemieux.activity." <> _suffix, "value" => value}
      },
      acc ->
        Map.put(acc, value["source"], Map.take(value, ["state", "reason"]))

      _entry, acc ->
        acc
    end)
  end
end
