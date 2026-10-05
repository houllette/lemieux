defmodule Lemieux.Subagent.Definition do
  @moduledoc """
  A versioned, host-supplied definition for one delegated investigator.

  Definitions are data, not discovered configuration. A host validates the
  model, prompt, tool authority, and budget it is willing to fund, then passes
  the resulting struct to a session. In particular, v1 rejects every tool that
  does not certify itself read-only. Inferring safety from a shell command or
  an MCP annotation would turn a research task into ambient write authority.

  `digest/1` covers every behavior-bearing field. It is persisted beside child
  lineage so a result remains attributable after the host changes a definition
  with the same human-readable id.
  """

  alias Lemieux.Tool

  # Defaults, not ceilings. These were the same number, which made the default the
  # maximum: a host could not ask for a longer-running child at all.
  #
  # None of the three is what stops a runaway — spend is bounded in dollars or
  # requests, and a loop is caught by the session's three-identical-rounds stop and
  # by `Lemieux.Progress` at every check. So `timeout` is a hard ceiling set high
  # enough that a working child never meets it, `progress_interval` is how often a
  # running child is asked whether it is going anywhere, and turns are the dial a
  # host turns down for a cheaper child.
  #
  # Two minutes was the hard deadline, and on 2026-09-18 it killed three scouts in
  # one session mid-answer after thirty distinct reads apiece. It is now the first
  # check instead: a child that finishes inside it is never assessed, and one still
  # reading distinct files at the mark is asked, not killed.
  @default_max_turns 400
  @default_timeout :timer.hours(1)
  @default_progress_interval :timer.minutes(2)
  @id ~r/\A[a-z][a-z0-9-]{0,63}\z/
  @default_result_schema :"Elixir.Lemieux.Subagent.Result"

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t(),
          system_prompt: String.t(),
          model: String.t(),
          tools: [Tool.t()],
          max_turns: pos_integer(),
          timeout: pos_integer(),
          progress_interval: pos_integer(),
          max_cost_usd: number() | nil,
          max_requests: pos_integer() | nil,
          result_schema: module(),
          metadata: map()
        }

  @enforce_keys [:id, :description, :system_prompt, :model]
  defstruct id: nil,
            description: nil,
            system_prompt: nil,
            model: nil,
            tools: [],
            max_turns: @default_max_turns,
            timeout: @default_timeout,
            progress_interval: @default_progress_interval,
            max_cost_usd: nil,
            max_requests: nil,
            result_schema: @default_result_schema,
            metadata: %{}

  @doc "Builds and validates a definition, raising on invalid authority or limits."
  @spec new(opts :: keyword()) :: t()
  def new(opts) when is_list(opts) do
    opts
    |> then(&struct!(__MODULE__, &1))
    |> validate!()
  end

  @doc "Validates an existing definition and returns it."
  @spec validate!(definition :: t()) :: t()
  def validate!(%__MODULE__{} = definition) do
    validate_id!(definition.id)
    validate_text!(:description, definition.description)
    validate_text!(:system_prompt, definition.system_prompt)
    validate_text!(:model, definition.model)
    validate_turns!(definition.max_turns)
    validate_timeout!(definition.timeout)
    validate_interval!(definition.progress_interval)
    validate_budget!(definition)
    validate_metadata!(definition.metadata)
    validate_result_schema!(definition.result_schema)
    validate_tools!(definition.tools)
    definition
  end

  @doc "Returns the stable SHA-256 digest of behavior-bearing definition data."
  @spec digest(definition :: t()) :: String.t()
  def digest(%__MODULE__{} = definition) do
    definition
    |> validate!()
    |> canonical()
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp canonical(definition) do
    %{
      "description" => definition.description,
      "id" => definition.id,
      "max_cost_usd" => definition.max_cost_usd,
      "max_turns" => definition.max_turns,
      "metadata" => definition.metadata,
      "model" => definition.model,
      "result_schema" => Atom.to_string(definition.result_schema),
      "system_prompt" => definition.system_prompt,
      "timeout" => definition.timeout,
      "tools" => Enum.map(definition.tools, &Tool.name/1)
    }
    |> request_bound(definition)
    |> interval(definition)
  end

  # Added only when set, so every definition written before request bounds
  # existed keeps its digest byte for byte — stored transcripts pin it.
  defp request_bound(canonical, %__MODULE__{max_requests: nil}), do: canonical

  defp request_bound(canonical, %__MODULE__{max_requests: n}),
    do: Map.put(canonical, "max_requests", n)

  # The same rule for the check interval: only a definition that chose one
  # digests differently from the one it was before the field existed.
  defp interval(canonical, %__MODULE__{progress_interval: @default_progress_interval}),
    do: canonical

  defp interval(canonical, %__MODULE__{progress_interval: ms}),
    do: Map.put(canonical, "progress_interval", ms)

  defp validate_id!(id) when is_binary(id) do
    if Regex.match?(@id, id), do: :ok, else: invalid!(:id, id)
  end

  defp validate_id!(id), do: invalid!(:id, id)

  defp validate_text!(_field, text) when is_binary(text) and byte_size(text) > 0, do: :ok
  defp validate_text!(field, value), do: invalid!(field, value)

  # Positive, and nothing more. A ceiling here refused configurations the runtime
  # would have clamped anyway — `Lemieux.Subagent.Group` takes the minimum of the
  # definition's timeout and what is left of the group's budget — so all it achieved
  # was turning a host's generous number into a raise instead of a clamp.
  defp validate_turns!(turns) when is_integer(turns) and turns > 0, do: :ok
  defp validate_turns!(turns), do: invalid!(:max_turns, turns)

  defp validate_timeout!(timeout) when is_integer(timeout) and timeout > 0, do: :ok
  defp validate_timeout!(timeout), do: invalid!(:timeout, timeout)

  defp validate_interval!(ms) when is_integer(ms) and ms > 0, do: :ok
  defp validate_interval!(ms), do: invalid!(:progress_interval, ms)

  # A child is bounded in dollars or in requests, and must be bounded in one of
  # them. Dollars were the only currency, which made a child impossible to run on a
  # route that cannot price one: `Lemieux.Session` refuses a request it cannot price
  # against a cost cap, so on a quota subscription every child stopped before its
  # first request and came back `budget_exhausted` with an empty answer.
  defp validate_budget!(%__MODULE__{max_cost_usd: nil, max_requests: nil} = definition),
    do: invalid!(:max_cost_usd, definition.max_cost_usd)

  defp validate_budget!(%__MODULE__{} = definition) do
    if is_nil(definition.max_cost_usd) or
         (is_number(definition.max_cost_usd) and definition.max_cost_usd > 0),
       do: :ok,
       else: invalid!(:max_cost_usd, definition.max_cost_usd)

    if is_nil(definition.max_requests) or
         (is_integer(definition.max_requests) and definition.max_requests > 0),
       do: :ok,
       else: invalid!(:max_requests, definition.max_requests)
  end

  defp validate_metadata!(metadata) when is_map(metadata) do
    JSON.encode!(metadata)
    :ok
  rescue
    _error -> invalid!(:metadata, metadata)
  end

  defp validate_metadata!(metadata), do: invalid!(:metadata, metadata)

  defp validate_result_schema!(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :schema, 0) and
         function_exported?(module, :decode, 1),
       do: :ok,
       else: invalid!(:result_schema, module)
  end

  defp validate_result_schema!(module), do: invalid!(:result_schema, module)

  defp validate_tools!(tools) when is_list(tools) do
    with :ok <- Tool.validate_all(tools),
         [] <- Enum.reject(tools, &Tool.read_only?/1) do
      :ok
    else
      {:error, reason} -> raise ArgumentError, "invalid subagent tools: #{inspect(reason)}"
      unsafe -> raise ArgumentError, "subagent tools must be read-only: #{tool_names(unsafe)}"
    end
  end

  defp validate_tools!(tools), do: invalid!(:tools, tools)

  defp tool_names(tools), do: Enum.map_join(tools, ", ", &Tool.name/1)

  defp invalid!(field, value) do
    raise ArgumentError, "invalid subagent definition #{field}: #{inspect(value)}"
  end
end
