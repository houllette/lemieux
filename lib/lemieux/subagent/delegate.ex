defmodule Lemieux.Subagent.Delegate do
  @moduledoc """
  The single model-facing tool for bounded delegated investigations.

  A host constructs this tool from already-validated definitions, a versioned
  workspace snapshot, and a mandatory tree budget. The model may choose a
  definition and write a bounded task brief; it cannot choose a new model,
  tool, credential, filesystem scope, provider, or budget. The call blocks only
  its supervised tool task while child sessions remain independently
  inspectable and cancellable.

  ## Built by the host, handed to the session like any other tool

  `Lemieux.Session` used to assemble this tool itself inside `init/1`, from
  five `:subagent_*` options. That gave one tool a privileged path into the
  session that no host tool had, and the seams grew around it: `tools/1`
  needed a paragraph explaining why a front end could not rebuild the catalog
  it was given, and every host had to learn a second vocabulary for what was
  a tool all along. Now the host calls `new/2` and passes the result in
  `:tools`. Everything the host decides — definitions, snapshot, budgets,
  child options — goes in at construction; everything only the session knows
  — its pid, id, supervisor, root and store — `run/3` reads from the tool
  context at call time through the session's delegation context. The
  same struct therefore works in any session it is handed to.

  It goes in `:tools`, not `:host_tools`, because it is part of what the
  model may call and what `Lemieux.Session.tools/1` hands back, so a front
  end that swaps the catalog keeps it. It is still never restored: the
  session records only module tools, and this is a struct holding functions
  and authority, so a resumed session gets the delegate the host resuming it
  passes and no other. `lmx` requires `--delegate` again on resume for that
  reason, and `Lemieux.CLI.Runtime` says how it re-equips one.
  """

  alias Lemieux.Subagent
  alias Lemieux.Subagent.Context
  alias Lemieux.Subagent.Definition
  alias Lemieux.Subagent.Group.Result
  alias Lemieux.Subagent.Request
  alias Lemieux.Subagent.Task

  @type t :: %__MODULE__{
          definitions: %{required(String.t()) => Definition.t()},
          context: map() | nil,
          snapshot: map(),
          max_cost_usd: number(),
          max_requests: pos_integer() | nil,
          options: keyword()
        }

  @enforce_keys [:definitions, :snapshot, :max_cost_usd]
  defstruct [:definitions, :snapshot, :max_cost_usd, :max_requests, :context, options: []]

  # The call's own deadline, as the descriptor declares it. It matches the
  # group's default so that a fan-out which runs for tens of minutes is not
  # stopped by the tool that asked for it; the session's `tool_timeout_ms`
  # still caps it.
  @deadline :timer.hours(1)

  # What the group keeps back from the call's deadline: long enough to cancel every
  # child, wait the grace interval and write the group result, so the call returns
  # what the children found instead of being killed mid-settle. That was the
  # failure — the tool task stopped at its clock, the group ran on to its own, and
  # it wrote results the parent never read.
  @settle_ms :timer.seconds(15)

  # What a fan-out may bring back into the parent's context: three answers
  # at `Lemieux.Subagent.Result`'s bound with their envelopes. The session's
  # `tool_output_bytes` still caps it, and `run/3` renders to whichever is
  # smaller rather than letting the session cut the JSON afterwards.
  @max_output_bytes 120_000

  @doc """
  Builds a delegate tool from explicit host configuration.

  `definitions` are validated `Lemieux.Subagent.Definition` values; the model
  may choose among them and nothing else. Required in `opts`: `:snapshot`, a
  non-empty versioned map every child inherits, and `:max_cost_usd`, the
  cumulative tree ceiling in dollars. `:max_requests` is the ceiling in
  requests, for a route that cannot price a child — the only bound that
  constrains one, since dollars are not a currency an unpriced route can be
  held to. Anything else — `:providers`, `:child_options`, `:policy`, a
  `:deadline_ms` allowance — is handed to `Lemieux.Subagent.spawn_many/3` as
  the group's options on every call.

  Raises `ArgumentError` for what cannot work: no definitions, duplicate ids,
  a missing or empty snapshot, a non-positive budget, or a definition whose
  own request budget the tree could never admit. Configuration is where a
  mistake can be named once; at run time the model would spend a turn finding
  it.
  """
  @spec new(definitions :: [Definition.t()], opts :: keyword()) :: t()
  def new(definitions, opts) when is_list(definitions) and is_list(opts) do
    definitions = Enum.map(definitions, &Definition.validate!/1)
    ids = Enum.map(definitions, & &1.id)

    snapshot = Keyword.get(opts, :snapshot)
    max_cost_usd = Keyword.get(opts, :max_cost_usd)
    max_requests = Keyword.get(opts, :max_requests)

    validate!(definitions, ids, snapshot, max_cost_usd, max_requests)

    context = Context.validate!(Keyword.get(opts, :context))

    %__MODULE__{
      definitions: Map.new(definitions, &{&1.id, &1}),
      snapshot: snapshot,
      context: context,
      max_cost_usd: max_cost_usd,
      max_requests: max_requests,
      options: Keyword.drop(opts, [:snapshot, :max_cost_usd, :max_requests, :context])
    }
  end

  defp validate!(definitions, ids, snapshot, max_cost_usd, max_requests) do
    require!(definitions != [], "delegate needs at least one definition")
    require!(length(ids) == length(Enum.uniq(ids)), "delegate definition ids must be unique")

    require!(
      is_map(snapshot) and map_size(snapshot) > 0,
      "delegate needs a :snapshot, a non-empty versioned map every child inherits"
    )

    require!(
      positive_number?(max_cost_usd),
      "delegate needs a positive :max_cost_usd, the tree's cumulative budget"
    )

    require!(ceiling?(max_requests), "delegate max_requests must be a positive integer")
    require!(admissible?(definitions, max_requests), oversized(definitions, max_requests))
  end

  # A child whose own request budget exceeds the tree's can never be admitted:
  # `Lemieux.Subagent.Admission` refuses the reservation, so every call fails with
  # `:root_request_budget_exhausted` and the model spends a turn discovering it. The
  # runtime message is clear, just three turns too late — the mistake is in
  # configuration, where it can be named once.
  defp admissible?(_definitions, nil), do: true

  defp admissible?(definitions, tree),
    do: Enum.all?(definitions, &((&1.max_requests || 0) <= tree))

  defp oversized(definitions, tree) do
    over =
      definitions
      |> Enum.filter(&((&1.max_requests || 0) > tree))
      |> Enum.map_join(", ", &"#{&1.id} asks for #{&1.max_requests}")

    "delegate max_requests #{tree} cannot admit a child that reserves more: #{over}"
  end

  defp require!(true, _message), do: :ok
  defp require!(_false, message), do: raise(ArgumentError, message)

  defp positive_number?(value), do: is_number(value) and value > 0
  defp ceiling?(value), do: is_nil(value) or (is_integer(value) and value > 0)

  @behaviour Lemieux.Tool.Configured

  @impl Lemieux.Tool.Configured
  def name(_tool), do: "delegate"

  # This text is the only place a model is ever told anything about delegating: the
  # default system prompt is explicit about staying short, and a workspace's own
  # instructions say nothing unless somebody wrote it there. Until the threshold was
  # here, the description said only what the tool *could* do, which reads as an
  # instruction to use it — a session on 2026-09-18 answered "tell me about this
  # repo" by spawning a scout with four-part acceptance criteria.
  #
  # The five-times figure is measured rather than rhetorical; `Lemieux.CLI.Options`
  # records the experiment. A model that knows it declines the tool for the cases
  # where it is only an expensive way to read.
  @impl Lemieux.Tool.Configured
  def description(%__MODULE__{} = tool) do
    definitions =
      tool.definitions
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_join("; ", fn {id, definition} -> "#{id}: #{definition.description}" end)

    """
    Run one to three read-only investigations at once, each in a fresh child \
    session with its own context, and get back one ordered result once all of \
    them have settled. You remain the only writer and the only decision-maker.

    Use this when the work genuinely splits into separate questions that do \
    not depend on each other's answers, or when the reading is wide enough \
    that pulling all of it through this conversation would crowd out the work \
    itself.

    Do not use it for anything you could answer with a few reads, a search, or \
    one command — read it yourself instead. A child starts with none of this \
    conversation, so every task has to be briefed from scratch, and what comes \
    back is its prose rather than the files. Measured over thirty read-heavy \
    tasks, delegating reached the same answers as reading directly and spent \
    about five times the tokens. When it is a close call, read it yourself.

    Available definitions: #{definitions}\
    """
  end

  @impl Lemieux.Tool.Configured
  def schema(tool) do
    %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["tasks"],
      "properties" => %{
        "tasks" => %{
          "type" => "array",
          "minItems" => 1,
          "maxItems" => 3,
          "items" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ~w(definition_id objective),
            "properties" => %{
              # An enum, not free text: in the investigator experiment a
              # model guessed a definition name on 13 of 30 first calls and
              # lost a turn to `unknown_definition` each time.
              "definition_id" => %{
                "type" => "string",
                "enum" => tool.definitions |> Map.keys() |> Enum.sort(),
                "description" => "Which investigator runs this task. Only the listed ids exist."
              },
              # Described, every one of them. A child receives the brief and
              # nothing else — not this conversation, not the reasoning that led
              # here — so these fields are the whole of what it knows, and bare
              # type declarations left a model to guess. The guesses were
              # plausible and generic, which is the expensive kind of wrong: a
              # vague objective is a child that reads widely and reports what
              # everybody knew.
              "objective" => %{
                "type" => "string",
                "description" =>
                  "What this child must find out, written for somebody who has " <>
                    "not seen this conversation. It is all the child gets."
              },
              "non_goals" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" =>
                  "What is deliberately out of scope, so the child does not " <>
                    "spend its budget widening the question."
              },
              "expected_evidence" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" =>
                  "The paths, commands or artefacts the answer should cite. " <>
                    "Name them when you know them; a child that has to find " <>
                    "the map first has less budget for the territory."
              },
              "acceptance_criteria" => %{
                "type" => "array",
                "items" => %{"type" => "string"},
                "description" =>
                  "What a complete answer contains, so the child can tell when " <>
                    "it is finished rather than when it runs out of turns."
              },
              "branch" => %{
                "type" => "string",
                "description" =>
                  "A sibling branch this child owns, when it is not reading the " <>
                    "working tree."
              },
              "references" => %{
                "type" => "array",
                "items" => %{"type" => "object"},
                "description" =>
                  "JSON pointers to things the child should start from — a path " <>
                    "with a digest, a transcript entry id. Facts, not prose."
              }
            }
          }
        }
      }
    }
  end

  # The schema asks for an array and a model sometimes sends the object it would
  # have put inside one — `"references": {}` killed a whole delegate call, taking
  # three children's work with it. An empty object carries the same information as
  # an empty array, and a populated one is the single element the model meant.
  # `Lemieux.Subagent.Task` stays strict; leniency belongs at the boundary where
  # model output is read.
  defp listed(task, key) do
    case Map.get(task, key, []) do
      list when is_list(list) -> list
      map when is_map(map) and map_size(map) == 0 -> []
      map when is_map(map) -> [map]
      nil -> []
      other -> [other]
    end
  end

  # A delegation that produced nothing is a failed call, not data. This returned
  # `{:ok, json}` whatever happened, so a parent whose children all died received a
  # *successful* tool result and had to notice the emptiness inside a JSON blob —
  # and a parent that did not notice answered anyway, reporting a plausible number
  # it held no tool to read and no child had mentioned. `error?: true` is the
  # difference between a result a model reads and one it must account for.
  @doc false
  def outcome(result, budget \\ @max_output_bytes)

  def outcome(%Result{status: status} = result, budget) when status in [:ok, :partial],
    do: {:ok, Result.render(result, budget)}

  def outcome(%Result{} = result, budget) do
    heading = nothing_returned(result) <> "\n\n"
    {:error, heading <> Result.render(result, max(budget - byte_size(heading), 1_024))}
  end

  # The bound the session will apply to this call's result, so the rendering
  # fits it by design rather than by having its JSON cut afterwards.
  defp budget(%{tool_output_bytes: bytes}) when is_integer(bytes) and bytes > 0,
    do: min(bytes, @max_output_bytes)

  defp budget(_context), do: @max_output_bytes

  defp nothing_returned(%Result{results: results}) do
    reasons =
      results
      |> Enum.flat_map(& &1.uncertainties)
      |> Enum.uniq()
      |> Enum.reject(&(&1 == ""))

    count = length(results)
    plural = if count == 1, do: "investigation", else: "investigations"

    "no findings: all #{count} #{plural} ended without an answer" <>
      case reasons do
        [] -> "."
        reasons -> " (#{Enum.join(reasons, "; ")})."
      end
  end

  @impl Lemieux.Tool.Configured
  def parallel_safe?(_tool), do: false

  @impl Lemieux.Tool.Configured
  def read_only?(_tool), do: false

  @impl Lemieux.Tool.Configured
  def metadata(%__MODULE__{}) do
    %{
      effects: %{class: "delegated_read", resource_types: ["agent_tree"]},
      runtime: %{
        timeout_ms: @deadline,
        max_output_bytes: @max_output_bytes,
        concurrency: %{class: "exclusive"}
      }
    }
  end

  @impl Lemieux.Tool.Configured
  def run(%__MODULE__{} = tool, %{"tasks" => tasks}, context) when is_list(tasks) do
    with {:ok, requests} <- requests(tool, tasks),
         {:ok, group_ref} <-
           Subagent.spawn_many(
             context.session,
             requests,
             tool.options
             |> Keyword.put(:max_cost_usd, tool.max_cost_usd)
             |> Keyword.put(:max_requests, tool.max_requests)
             |> within_call_deadline(context)
           ),
         {:ok, result} <- Subagent.await(group_ref, :infinity) do
      outcome(result, budget(context))
    else
      {:error, reason} -> {:error, describe(reason)}
    end
  end

  def run(%__MODULE__{}, _args, _context), do: {:error, "delegate requires a tasks array"}

  # The group may not outlive the call that is waiting for it. The session
  # says what clock this call got; the group is given that, less the time it
  # needs to settle, and a host allowance already in the options still binds
  # if it is shorter.
  defp within_call_deadline(opts, %{deadline_ms: deadline}) when is_integer(deadline) do
    derived = max(deadline - @settle_ms, 1_000)
    Keyword.update(opts, :deadline_ms, derived, &min(&1, derived))
  end

  defp within_call_deadline(opts, _context), do: opts

  defp requests(tool, tasks) when length(tasks) in 1..3 do
    tasks
    |> Enum.reduce_while({:ok, []}, fn task, {:ok, requests} ->
      case request(tool, task) do
        {:ok, request} -> {:cont, {:ok, [request | requests]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, requests} -> {:ok, Enum.reverse(requests)}
      error -> error
    end)
  end

  defp requests(_tool, tasks), do: {:error, {:fan_out_limit, length(tasks)}}

  @doc false
  def request(tool, %{"definition_id" => definition_id, "objective" => objective} = task) do
    case Map.fetch(tool.definitions, definition_id) do
      {:ok, definition} ->
        task =
          Task.new(
            objective: objective,
            non_goals: listed(task, "non_goals"),
            expected_evidence: listed(task, "expected_evidence"),
            acceptance_criteria: listed(task, "acceptance_criteria"),
            branch: Map.get(task, "branch"),
            references: listed(task, "references"),
            snapshot: tool.snapshot,
            context: tool.context
          )

        {:ok, Request.new(definition, task)}

      :error ->
        {:error, {:unknown_definition, definition_id, Map.keys(tool.definitions) |> Enum.sort()}}
    end
  rescue
    error in ArgumentError -> {:error, Exception.message(error)}
  end

  def request(_tool, _task), do: {:error, :invalid_task}

  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: inspect(reason)
end
