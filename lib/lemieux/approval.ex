defmodule Lemieux.Approval.Request do
  @moduledoc "A live, single-use approval challenge. Never restore it from transcript evidence."
  @type t :: %__MODULE__{
          version: 1,
          id: String.t(),
          nonce: String.t(),
          scope: String.t(),
          call_id: String.t(),
          session_id: String.t(),
          run_id: String.t(),
          expires_at: integer()
        }
  @enforce_keys [:id, :nonce, :scope, :call_id, :session_id, :run_id, :expires_at]
  @derive {Inspect, except: [:nonce]}
  defstruct @enforce_keys ++ [version: 1]
end

defmodule Lemieux.Approval.Runtime do
  @moduledoc false
  @derive {Inspect, only: [:mode, :ttl_ms]}
  defstruct [:mode, :ttl_ms, :context, :key]
end

defmodule Lemieux.Approval do
  @moduledoc """
  Optional scoped resolution over the session's existing approval queue.

  Set `:approval_mode` to `:scoped` and install a runtime `:ingress`
  (`Lemieux.Ingress`). A pending tool call then exposes a live
  `Lemieux.Approval.Request` through `Session.approval_request/2`. Resolve it
  with `Session.resolve_approval/4`, a decision and an untrusted ingress claim.
  Only the host's attestor can establish resolver provenance.

  `:allow_once` binds the validated arguments, actual executor and loaded
  implementation, descriptor, session/run, cwd and environment. The binding
  is checked again immediately before invocation, after all hooks. Hosts with
  mutable external state supply `:approval_context`, a bounded arity-one
  function returning an execution epoch or other relevant context. A PID or
  remote handle alone cannot describe changes inside the resource it names.
  This guard is not an atomic transaction with an external execution backend;
  hosts needing that guarantee must enforce the epoch when committing effects.

  `{:request_rewrite, args}` is a proposal: it consumes the old challenge,
  validates the new arguments and parks again with a new nonce. It grants no
  execution. `{:deny, reason}` refuses the action. No broader grant is implied.

  Challenges expire after `:approval_ttl_ms` (default and maximum five minutes),
  cancellation or consumption. They are runtime-only, use a fresh per-session
  HMAC key, and cannot be restored on resume. Approval audit records contain
  keyed scope digests and bounded attestor references, without nonce, arguments,
  prompt, credentials or output. The ordinary transcript still records its
  normal conversation and tool results.

  The default `:legacy` mode retains `Session.resolve_tool/3` and stock UI
  behavior, with resolver provenance explicitly unknown. Scoped hosts reject
  legacy resolution and must adapt their authenticated ingress/UI; a click
  alone is not an identity contract. Runtime host code remains trusted.
  """

  alias Lemieux.Approval.Request
  alias Lemieux.Approval.Runtime
  alias Lemieux.Clock
  alias Lemieux.StructuredResult
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor

  @type decision :: :allow_once | {:deny, String.t()} | {:request_rewrite, map()}

  @doc false
  @spec options(opts :: keyword()) :: struct()
  def options(opts) do
    mode = Keyword.get(opts, :approval_mode, :legacy)
    ttl = Keyword.get(opts, :approval_ttl_ms, 300_000)
    context = Keyword.get(opts, :approval_context)
    host_timeout = Keyword.get(opts, :approval_timeout, :infinity)

    unless mode in [:legacy, :scoped] and is_integer(ttl) and ttl in 1..300_000 and
             (is_nil(context) or is_function(context, 1)),
           do: raise(ArgumentError, "approval mode, TTL or context callback is invalid")

    ttl = if is_integer(host_timeout) and host_timeout > 0, do: min(ttl, host_timeout), else: ttl

    %Runtime{
      mode: mode,
      ttl_ms: ttl,
      context: context,
      key: if(mode == :scoped, do: :crypto.strong_rand_bytes(32))
    }
  end

  @doc false
  @spec context(runtime :: struct() | nil, tool :: Tool.t(), context :: map()) :: map()
  def context(%{mode: :scoped} = runtime, tool, context) do
    Map.merge(context, %{
      approval_mode: :scoped,
      approval_factory: fn nested_tool, nested_context ->
        context(runtime, nested_tool, nested_context)
      end,
      approval_scope: fn args -> binding(runtime, tool, args, context) end
    })
  end

  def context(_legacy, _tool, context), do: context

  @doc false
  @spec binding(runtime :: struct(), tool :: Tool.t(), arguments :: map(), context :: map()) ::
          String.t()
  def binding(runtime, tool, args, context) do
    external = if runtime.context, do: runtime.context.(context)
    module = executor_module(tool)

    action =
      {tool, Tool.descriptor(tool).digest, module.module_info(:md5), args,
       Map.take(context, [:cwd, :environment, :session_id, :run_id, :call_id]), external}

    :crypto.mac(:hmac, :sha256, runtime.key, :erlang.term_to_binary(action))
    |> Base.encode16(case: :lower)
  end

  defp executor_module(%{__struct__: Descriptor, executor: executor}),
    do: executor_module(executor)

  defp executor_module(%{__struct__: module}), do: module
  defp executor_module(module) when is_atom(module), do: module

  @doc false
  @spec validate(arguments :: map(), context :: map()) :: :ok | {:deny, String.t()}
  def validate(args, %{approval_mode: :scoped, tool_descriptor: descriptor}) do
    schema = get_in(descriptor, ["interface", "input_schema"])

    with true <- :erlang.external_size(args) <= 1_048_576,
         {:ok, _contract} <- StructuredResult.new(schema),
         {:ok, _validated} <- ReqLLM.Schema.validate(args, schema) do
      :ok
    else
      _invalid -> {:deny, "scoped approval arguments do not match a bounded local tool schema"}
    end
  end

  def validate(_args, _legacy), do: :ok

  @doc false
  @spec verify(grants :: [String.t()], arguments :: map(), context :: map()) ::
          :ok | {:deny, String.t()}
  def verify([], _args, _context), do: :ok

  def verify(grants, args, %{approval_scope: scope}) do
    current = scope.(args)

    if Enum.all?(grants, &(&1 == current)),
      do: :ok,
      else: {:deny, "approval scope changed; fresh approval is required"}
  end

  @doc false
  @spec request(state :: map(), call_id :: String.t(), scope :: String.t()) :: Request.t()
  def request(state, call_id, scope) do
    %Request{
      id: "approval_" <> Lemieux.ID.generate(),
      nonce: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
      scope: scope,
      call_id: call_id,
      session_id: state.id,
      run_id: state.evidence.current_run.id,
      expires_at: Clock.now_ms(state.clock) + state.approval.ttl_ms
    }
  end

  @doc false
  @spec audit(request :: Request.t()) :: map()
  def audit(request),
    do: %{
      "version" => 1,
      "request_id" => request.id,
      "scope" => request.scope,
      "session_id" => request.session_id,
      "run_id" => request.run_id,
      "expires_at" => request.expires_at
    }

  @doc false
  @spec valid_decision?(decision :: term()) :: boolean()
  def valid_decision?(:allow_once), do: true
  def valid_decision?({:deny, reason}), do: is_binary(reason) and byte_size(reason) <= 4_096

  def valid_decision?({:request_rewrite, args}),
    do: is_map(args) and :erlang.external_size(args) <= 1_048_576

  def valid_decision?(_invalid), do: false
end
