defmodule Lemieux.Tool.Configured do
  @moduledoc """
  The contract for a tool that is a struct rather than a module.

  `Lemieux.Tool` is implemented by a bare module when a tool needs nothing but
  its code. A tool that exists only once a host has handed it something at
  runtime — a remote command runner, a search backend and a budget, the skill
  files a host discovered — has state a module has nowhere to keep, so it is
  a struct, and its operations take the struct as their first argument. This
  behaviour is those operations: the four required `Lemieux.Tool` callbacks
  with one more argument, and the same three optional ones.

  ## Why a behaviour, when dispatch never checks for it

  `Lemieux.Tool.validate_all/1` accepts any struct whose module exports the
  four required functions, whether or not it declares this behaviour, so a
  host's existing struct tool keeps working without a code change. What the
  declaration buys is the compiler: a struct tool with `run/2` where `run/3`
  was meant is a warning at compile time instead of a validation failure at
  session start, and `@impl` catches a renamed callback. The validation
  error for a struct that is short of a function names the function and this
  module, so the fix is one attribute away rather than a search.

  ## What the struct is and is not

  The struct is host-owned executable state. It may hold functions, pids and
  credentials, and for exactly that reason a session records module tools by
  name and leaves configured ones out of its `:session` entry; the host that
  built one passes it again on resume (`Lemieux.Tool.Override` gives the
  reasoning, which is the same for every struct tool). Nothing in the struct
  reaches the model or the transcript except through `c:name/1`,
  `c:description/1`, `c:schema/1` and `c:metadata/1`.
  """

  alias Lemieux.Tool
  alias Lemieux.Tool.Result

  @doc "The name the model calls this tool by."
  @callback name(tool :: struct()) :: String.t()

  @doc "What the tool does, as the model reads it."
  @callback description(tool :: struct()) :: String.t()

  @doc "A JSON Schema object describing the arguments."
  @callback schema(tool :: struct()) :: map()

  @doc """
  Does the thing. The contract is `c:Lemieux.Tool.run/2`'s, with the struct in front.
  """
  @callback run(tool :: struct(), args :: Tool.args(), context :: Tool.context()) ::
              {:ok, iodata() | Result.t()} | {:error, term()} | {:stream, Enumerable.t()}

  @doc "See `c:Lemieux.Tool.parallel_safe?/0`; the default is `false`."
  @callback parallel_safe?(tool :: struct()) :: boolean()

  @doc "See `c:Lemieux.Tool.read_only?/0`; the default is `false`."
  @callback read_only?(tool :: struct()) :: boolean()

  @doc "Descriptor-v1 metadata, as `c:Lemieux.Tool.metadata/0`."
  @callback metadata(tool :: struct()) :: map()

  @optional_callbacks parallel_safe?: 1, read_only?: 1, metadata: 1

  @required [name: 1, description: 1, schema: 1, run: 3]

  @doc """
  The required callbacks `module` does not export, in the order they are declared.

  Empty for any module a configured tool can be dispatched to, whether or not
  it declares the behaviour. This is the question `Lemieux.Tool.validate_all/1`
  asks of a struct.
  """
  @spec missing_callbacks(module :: module()) :: [{atom(), arity()}]
  def missing_callbacks(module) when is_atom(module) do
    if Code.ensure_loaded?(module),
      do: Enum.reject(@required, fn {name, arity} -> function_exported?(module, name, arity) end),
      else: @required
  end
end
