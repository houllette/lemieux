defmodule Lemieux.Writers.Tool do
  @moduledoc """
  A configured writer capability for an ordinary agent tool catalog.

  Required host options: `:paths` (maximum relative ownership), `:tools` (writer
  tool names), and `:options` (the policy required by `Lemieux.Writers.start/3`).
  Optional ceilings: `:max_writers` (4), `:max_requests` per writer (40), and
  `:max_batches` (1, or 2 with `:workspace_factory`). Multiple batches require
  a host `:workspace_factory` (`context -> {:ok, adapter}`) called afresh at
  each start. A static adapter may freeze its initial tree: reusing it after
  integration made a live follow-up writer see stubs instead of accepted code.
  All proposed scopes must be subsets of host grants. The
  model cannot select factories, credentials, environments, checks or authority.

  Each validated start attempt records its bounded rationale/interfaces/check expectations
  through the generic document seam; those expectations do not replace host
  checks. Failed allocations consume the attempt ceiling. A live parent's coordinator
  owns capabilities; only its id reaches the model. Reports and patches can be
  read in bounded pages after cleanup, including rejected attempts. Reviewing
  bytes does not prove understanding: integration requires complete retrieval
  of both files, current host
  review authorization and independent checks against explicit artifact digests.
  """
  @behaviour Lemieux.Tool.Configured
  alias Lemieux.Session
  alias Lemieux.Tool.Result
  alias Lemieux.Writers
  alias Lemieux.Writers.Artifact
  alias Lemieux.Writers.Plan

  @enforce_keys [:paths, :tools, :options, :max_writers, :max_requests, :max_batches]
  defstruct @enforce_keys ++ [:workspace_factory]

  @type t :: %__MODULE__{
          paths: [String.t()],
          tools: [String.t()],
          options: keyword(),
          max_writers: pos_integer(),
          max_requests: pos_integer(),
          max_batches: pos_integer(),
          workspace_factory:
            nil
            | (Lemieux.Tool.context() ->
                 {:ok, Lemieux.Writers.Workspace.adapter()} | {:error, term()})
        }
  @namespace "lemieux.writer_dispatch"
  @reviews "lemieux.writer_reviews"
  @keys ~w(action strategy reason interfaces checks tasks batch_id digest kind offset digests)

  @doc "Builds the capability only from explicit, bounded host policy."
  @spec new(opts :: keyword()) :: {:ok, t()} | {:error, term()}
  def new(opts) do
    options = Keyword.get(opts, :options, []) |> Keyword.put_new(:max_active, 4)

    tool = %__MODULE__{
      paths: opts[:paths],
      tools: opts[:tools],
      options: options,
      max_writers: Keyword.get(opts, :max_writers, 4),
      max_requests: Keyword.get(opts, :max_requests, 40),
      max_batches:
        Keyword.get(
          opts,
          :max_batches,
          if(is_function(opts[:workspace_factory], 1), do: 2, else: 1)
        ),
      workspace_factory: opts[:workspace_factory]
    }

    grant = %Plan{id: "grant", task: "host grant", paths: tool.paths, tools: tool.tools}
    validate_configuration(tool, grant)
  end

  defp validate_configuration(tool, grant) do
    cond do
      not (Plan.valid?(grant) and ceilings?(tool) and
               host_policy?(tool.options, tool.workspace_factory)) ->
        {:error, :missing_host_policy}

      tool.max_batches > 1 and not is_function(tool.workspace_factory, 1) ->
        {:error, :fresh_workspace_factory_required}

      not is_nil(tool.workspace_factory) and not is_function(tool.workspace_factory, 1) ->
        {:error, :invalid_workspace_factory}

      true ->
        {:ok, tool}
    end
  end

  defp ceilings?(tool) do
    tool.max_writers in 1..4 and positive?(tool.max_requests) and
      tool.max_batches in 1..20 and tool.options[:max_active] in 1..4
  end

  defp host_policy?(options, workspace_factory) do
    Keyword.has_key?(options, :authority) and
      (is_function(workspace_factory, 1) or
         match?({module, _state} when is_atom(module), options[:workspace])) and
      Enum.all?([factory: 2, verify: 3, checks: 1, authorize: 3], fn {key, arity} ->
        is_function(options[key], arity)
      end) and positive?(Keyword.get(options, :timeout_ms, 3_600_000))
  end

  @impl true
  def name(_tool), do: "writers"

  @impl true
  def metadata(tool) do
    %{
      effects: %{class: "delegated_write", resource_types: ["agent_tree", "filesystem"]},
      runtime: %{
        timeout_ms: Keyword.get(tool.options, :timeout_ms, 3_600_000),
        concurrency: %{class: "exclusive"}
      }
    }
  end

  @impl true
  def description(tool) do
    """
    Start, observe, review and integrate host-authorized isolated implementation
    sessions. Use only for substantial independent work with stable interfaces
    and disjoint file/test ownership. Work directly for small or tightly coupled
    changes. Start returns a batch id; do independent work, then await the batch
    rather than polling its commands. Writers hold their owned background work
    through completion. Review each patch and report
    (follow next_offset until null), then integrate explicitly accepted digests.
    Failed status is not success; inspect findings before replanning. Cancel
    stops work; close releases a settled coordinator. Never write delegated paths
    in the parent while the batch runs. Serial uses one active writer on the same
    shared base snapshot, not dependency-aware stages. All work shares this job's
    allowance. Host limits: #{tool.max_batches} start attempts, up to
    #{tool.max_writers} writers, #{tool.options[:max_active]} active, and
    #{tool.max_requests} requests per writer. Allowed ownership: #{Enum.join(tool.paths, ", ")}.
    """
  end

  @impl true
  def schema(tool) do
    string = %{"type" => "string"}
    strings = %{"type" => "array", "items" => string, "maxItems" => 16}

    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["action"],
      "properties" => %{
        "action" => %{
          "type" => "string",
          "enum" => ~w(start status await review integrate cancel close)
        },
        "strategy" => %{
          "type" => "string",
          "enum" => ["serial", "parallel"],
          "description" => "Required for start; parallel is bounded by host concurrency."
        },
        "reason" =>
          Map.put(
            string,
            "description",
            "Required for start: why isolation/delegation is worth its overhead."
          ),
        "interfaces" =>
          Map.put(
            strings,
            "description",
            "Required for start: stable shared contracts each independent writer receives."
          ),
        "checks" =>
          Map.put(
            strings,
            "description",
            "Required for start: expected checks, in addition to fixed host verification."
          ),
        "tasks" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => tool.max_writers,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ~w(id task paths),
            "properties" => %{
              "id" => string,
              "task" =>
                Map.put(
                  string,
                  "description",
                  "Self-contained brief; child has none of this conversation."
                ),
              "paths" => %{
                "type" => "array",
                "items" => string,
                "minItems" => 1,
                "maxItems" => 100,
                "description" =>
                  "Exact relative files or prefixes ending in /, within host ownership; no overlaps."
              }
            }
          }
        },
        "batch_id" =>
          Map.put(string, "description", "Required except for start: live batch id from start."),
        "digest" =>
          Map.put(string, "description", "Required for review: immutable artifact digest."),
        "kind" => %{
          "type" => "string",
          "enum" => ["patch", "report"],
          "description" => "Required for review."
        },
        "offset" => %{
          "type" => "integer",
          "minimum" => 0,
          "description" => "Review byte offset; defaults to 0."
        },
        "digests" =>
          Map.put(
            strings,
            "description",
            "Required for integrate: reviewed accepted artifact digests."
          )
      }
    }
  end

  @impl true
  def run(tool, args, context) when is_map(args) do
    with true <- Enum.all?(Map.keys(args), &(&1 in @keys)),
         :ok <- authorize(tool, args, context),
         {:ok, value} <- execute(tool, args, context),
         true <-
           byte_size(JSON.encode!(value)) <= (Map.get(context, :tool_output_bytes) || 30_000) do
      {:ok, Result.new(JSON.encode!(value), structured_content: value)}
    else
      false ->
        {:error,
         "writer arguments or output exceed host limits; use status or smaller review pages"}

      {:error, reason} ->
        {:error, inspect(reason, limit: 30, printable_limit: 2000)}
    end
  catch
    :exit, reason -> {:error, "writer coordinator unavailable: " <> inspect(reason, limit: 10)}
  end

  def run(_tool, _args, _context), do: {:error, "writer arguments must be an object"}

  defp authorize(tool, args, context) do
    tool.options[:authorize].(
      :tool,
      %{action: args["action"], parent_id: context.session_id},
      tool.options[:authority]
    )
  end

  defp execute(tool, %{"action" => "start"} = args, context) do
    with :ok <- selection(args),
         {:ok, plans} <- plans(tool, args),
         {:error, :not_running} <- Writers.current(context.session),
         :ok <- shared_parent(context.session),
         :ok <- record(tool, args, plans, context.session),
         {:ok, workspace} <- workspace(tool, context),
         max_active = if(args["strategy"] == "serial", do: 1, else: tool.options[:max_active]),
         {:ok, ref} <-
           Writers.start(
             context.session,
             plans,
             Keyword.merge(tool.options, max_active: max_active, workspace: workspace)
           ),
         {:ok, snapshot} <- Writers.snapshot(ref) do
      {:ok, %{"batch_id" => ref.id, "status" => to_string(snapshot.status)}}
    else
      {:ok, %Writers.Ref{}} -> {:error, :batch_already_open}
      error -> error
    end
  end

  defp execute(tool, %{"action" => action, "batch_id" => id} = args, context) do
    case Writers.current(context.session) do
      {:ok, %Writers.Ref{id: ^id} = ref} -> operate(tool, action, args, context, ref)
      {:ok, _ref} -> {:error, :unknown_batch}
      error -> error
    end
  end

  defp execute(_tool, _args, _context), do: {:error, :invalid_writer_action}

  defp shared_parent(session) do
    context = Session.delegation_context(session)

    cond do
      context.id != context.root_session_id -> {:error, :delegated_parent}
      not is_pid(context.job_budget) -> {:error, :shared_allowance_required}
      not Process.alive?(context.job_budget) -> {:error, :shared_allowance_required}
      true -> :ok
    end
  end

  defp workspace(%{workspace_factory: nil} = tool, _context), do: {:ok, tool.options[:workspace]}
  defp workspace(tool, context), do: tool.workspace_factory.(context)

  defp operate(_tool, "status", _args, _context, ref) do
    with {:ok, value} <- Writers.snapshot(ref), do: {:ok, projection(value)}
  end

  defp operate(_tool, "await", _args, context, ref) do
    timeout = max(1, min((Map.get(context, :deadline_ms) || 61_000) - 1_000, 60_000))

    case Writers.await(ref, timeout) do
      {:ok, value} ->
        {:ok, projection(value)}

      {:error, :timeout} ->
        with {:ok, value} <- Writers.snapshot(ref),
             do: {:ok, Map.put(projection(value), "await_timed_out", true)}

      error ->
        error
    end
  end

  defp operate(_tool, "review", args, context, ref) do
    with {:ok, value} <- Writers.snapshot(ref),
         %{artifact: %Artifact{} = artifact} <-
           Enum.find(value.writers, &(&1.artifact && &1.artifact.digest == args["digest"])),
         :ok <- Artifact.verify(artifact),
         kind when kind in ["patch", "report"] <- args["kind"],
         offset = Map.get(args, "offset", 0),
         true <- is_integer(offset) and offset >= 0,
         path = if(kind == "patch", do: artifact.patch_path, else: artifact.report_path),
         {:ok, bytes} <- File.read(path),
         true <- offset <= byte_size(bytes),
         limit =
           min(8000, div(max(0, (Map.get(context, :tool_output_bytes) || 30_000) - 2048), 6)),
         true <- limit > 0 do
      count = page_size(bytes, offset, min(limit, byte_size(bytes) - offset))
      next = offset + count

      with true <- count > 0 or offset == byte_size(bytes),
           :ok <-
             record_review(context.session, artifact.digest, kind, offset, next, byte_size(bytes)) do
        {:ok,
         %{
           "digest" => artifact.digest,
           "kind" => kind,
           "offset" => offset,
           "bytes" => byte_size(bytes),
           "encoding" => if(String.valid?(bytes), do: "utf8", else: "utf8_replacement"),
           "next_offset" => if(next < byte_size(bytes), do: next),
           "text" => Lemieux.Tool.sanitize(binary_part(bytes, offset, count))
         }}
      else
        false -> {:error, :invalid_review}
        error -> error
      end
    else
      _invalid -> {:error, :invalid_review}
    end
  end

  defp operate(tool, "integrate", %{"digests" => digests}, context, ref) do
    with :ok <- reviewed(context.session, digests),
         {:ok, _receipt} <- Writers.integrate(ref, digests, tool.options[:authority]),
         {:ok, value} <- Writers.snapshot(ref),
         do: {:ok, projection(value)}
  end

  defp operate(tool, action, _args, _context, ref) when action in ["cancel", "close"] do
    outcome =
      if(action == "cancel",
        do: Writers.cancel(ref, tool.options[:authority]),
        else: Writers.close(ref, tool.options[:authority])
      )

    status = if action == "cancel", do: "cancelled", else: "closed"
    with :ok <- outcome, do: {:ok, %{"batch_id" => ref.id, "status" => status}}
  end

  defp operate(_tool, _action, _args, _context, _ref), do: {:error, :invalid_writer_action}

  defp selection(args) do
    if args["strategy"] in ["serial", "parallel"] and text?(args["reason"], 2000) and
         texts?(args["interfaces"]) and texts?(args["checks"]),
       do: :ok,
       else: {:error, :invalid_selection}
  end

  defp plans(tool, %{"tasks" => tasks} = args) when is_list(tasks) and length(tasks) in 1..4 do
    plans =
      Enum.map(tasks, fn task ->
        if is_map(task) and Enum.sort(Map.keys(task)) == ~w(id paths task),
          do: %Plan{
            id: task["id"],
            task: brief(task["task"], args),
            paths: task["paths"],
            tools: tool.tools,
            max_requests: tool.max_requests
          }
      end)

    if length(plans) <= tool.max_writers and Enum.all?(plans, &Plan.valid?/1) and
         Enum.all?(plans, fn plan -> Enum.all?(plan.paths, &granted?(tool.paths, &1)) end),
       do: {:ok, plans},
       else: {:error, :scope_or_brief_not_granted}
  end

  defp plans(_tool, _tasks), do: {:error, :invalid_briefs}

  defp brief(task, args) when is_binary(task) do
    task <>
      "\n\nShared interfaces:\n" <>
      Enum.join(args["interfaces"], "\n") <>
      "\nExpected checks:\n" <> Enum.join(args["checks"], "\n")
  end

  defp brief(_task, _args), do: nil

  defp granted?(grants, path),
    do:
      Enum.any?(
        grants,
        &(&1 == path or (String.ends_with?(&1, "/") and String.starts_with?(path, &1)))
      )

  defp record(tool, args, plans, session) do
    with {:ok, document} <- Session.document(session, @namespace),
         attempts = (document.value || %{})["attempts"] || [],
         true <- length(attempts) < tool.max_batches,
         selection = Map.take(args, ~w(strategy reason interfaces checks)),
         value = %{
           "attempts" =>
             attempts ++
               [
                 Map.put(
                   selection,
                   "scopes",
                   Enum.map(plans, &%{"id" => &1.id, "paths" => &1.paths})
                 )
               ]
         },
         {:ok, _document} <- Session.put_document(session, @namespace, document.revision, value) do
      :ok
    else
      false -> {:error, :batch_limit}
      error -> error
    end
  end

  defp record_review(session, digest, kind, offset, next, size) do
    with {:ok, document} <- Session.document(session, @reviews),
         reviews = document.value || %{},
         key = digest <> "/" <> kind,
         prior = Map.get(reviews, key, %{"through" => 0, "size" => size}),
         true <- offset <= prior["through"] and prior["size"] == size,
         updated =
           Map.put(reviews, key, %{"through" => max(prior["through"], next), "size" => size}),
         {:ok, _document} <- Session.put_document(session, @reviews, document.revision, updated) do
      :ok
    else
      false -> {:error, :review_pages_must_be_contiguous}
      error -> error
    end
  end

  defp reviewed(session, digests) when is_list(digests) and digests != [] do
    with {:ok, document} <- Session.document(session, @reviews) do
      reviews = document.value || %{}

      if Enum.all?(digests, &reviewed_digest?(reviews, &1)),
        do: :ok,
        else: {:error, :complete_review_required}
    end
  end

  defp reviewed(_session, _digests), do: {:error, :complete_review_required}

  defp reviewed_digest?(reviews, digest) when is_binary(digest),
    do: Enum.all?(["patch", "report"], &complete_page?(reviews[digest <> "/" <> &1]))

  defp reviewed_digest?(_reviews, _digest), do: false
  defp complete_page?(%{"through" => size, "size" => size}), do: true
  defp complete_page?(_page), do: false

  # A byte cap must not split a valid UTF-8 patch's characters. Offsets stay in
  # original bytes; non-UTF-8 data is explicitly labelled as a replacement view.
  defp page_size(bytes, offset, count) do
    cond do
      not String.valid?(bytes) -> count
      not String.valid?(binary_part(bytes, 0, offset)) -> 0
      true -> utf8_size(bytes, offset, count)
    end
  end

  defp utf8_size(_bytes, _offset, 0), do: 0

  defp utf8_size(bytes, offset, count) do
    if String.valid?(binary_part(bytes, offset, count)),
      do: count,
      else: utf8_size(bytes, offset, count - 1)
  end

  defp projection(value) do
    %{
      "batch_id" => value.id,
      "status" => to_string(value.status),
      "integration" => value.integration,
      "budget" => if(value.budget, do: Map.new(value.budget, fn {k, v} -> {to_string(k), v} end)),
      "writers" =>
        Enum.map(value.writers, fn writer ->
          %{
            "id" => writer.id,
            "status" => to_string(writer.status),
            "transcript_id" => writer.transcript_id,
            "error" =>
              if(writer.error, do: inspect(writer.error, limit: 20, printable_limit: 512)),
            "artifact" =>
              if(writer.artifact,
                do:
                  Map.put(
                    Artifact.reference(writer.artifact),
                    "verification",
                    verification(writer.artifact.verification)
                  )
              )
          }
        end)
    }
  end

  defp text?(value, limit), do: is_binary(value) and byte_size(value) in 1..limit

  defp verification(evidence) do
    %{
      "status" => evidence["status"],
      "check" =>
        if(is_binary(evidence["check"]), do: Lemieux.Tool.truncate(evidence["check"], 256))
    }
  end

  defp texts?(values),
    do: is_list(values) and length(values) in 1..16 and Enum.all?(values, &text?(&1, 2000))

  defp positive?(value), do: is_integer(value) and value > 0
end
