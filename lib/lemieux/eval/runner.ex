defmodule Lemieux.Eval.Runner do
  @moduledoc """
  Evaluates a string of Elixir, somewhere that is not here.

  This is the half of `Lemieux.Tools.Eval` that runs on the far side: on the
  evaluation node `Lemieux.Eval.Sandbox` starts, and later on whatever node a
  person attaches to. It is called across a node boundary, never locally.

  ## Two constraints, and they are the whole design

  **It references nothing from `Lemieux`.** Not the tool that calls it, not
  `Lemieux.Tool.truncate/2`, nothing. The point of that is the attach case: the
  node being evaluated on is somebody's running Phoenix app, which has never
  heard of lemieux, and the only thing that gets sent over is this module's
  own object code. A single `Lemieux.Anything` reference here turns loading it
  into loading half the library, on a node that did not ask for it.

  **Everything it returns survives the trip back.** Binaries, atoms, integers
  and lists of them — never a term whose module exists only over there. An
  exception raised by project code is formatted **on the node that raised it**,
  where the module defining it is loaded; sent back as a struct it would arrive
  somewhere that cannot decode it, and the useful half of the failure — what
  actually went wrong — would be lost to a mechanical error about the failure
  being undecodable.

  ## What it enforces, and what it does not

  Resource limits, not capability limits. Evaluated code may read the
  filesystem, spawn processes and run commands: that is the point of the tool,
  and it is why the node it runs on is not the one holding the transcript.

    * a wall-clock timeout, killing the process that overran it;
    * a maximum heap, so a runaway allocation kills one process rather than
      the node — and, on a node that is not ours, rather than the application;
    * captured output, so `IO.puts` reaches the model instead of a terminal
      nobody is watching;
    * a cap on how much of that output comes back.

  There is deliberately no attempt to restrict *what* the code may do by
  inspecting it first. A scan of an AST is not a security boundary — it is a
  speed bump with a false sense of safety attached, and `apply/3` walks around
  any of them. The boundary is the node.
  """

  @typedoc """
  What an evaluation produced.

  `output` is whatever was written to standard output, and `result` is the
  inspected return value — both already strings, both already truncated.
  """
  @type outcome ::
          {:ok, %{output: binary(), result: binary()}}
          | {:error, %{output: binary(), message: binary()}}

  @doc """
  Evaluates `code`, and says what happened.

  Options, all required by the caller rather than defaulted here, because the
  caller is the one that knows what a session is willing to spend:

    * `:timeout` — milliseconds before the evaluation is killed.
    * `:max_heap_words` — the evaluating process's heap cap, in words.
    * `:max_output` — bytes of captured output and of inspected result.
    * `:cwd` — the directory to evaluate in.
  """
  @spec eval(code :: binary(), opts :: keyword()) :: outcome()
  def eval(code, opts) when is_binary(code) and is_list(opts) do
    timeout = Keyword.fetch!(opts, :timeout)
    parent = self()

    {pid, ref} = spawn_monitor(fn -> send(parent, {self(), evaluate(code, opts)}) end)

    receive do
      {^pid, outcome} ->
        Process.demonitor(ref, [:flush])
        outcome

      # The heap cap fires as an exit of the evaluating process, so the two
      # arrive here the same way and are told apart only by the reason.
      {:DOWN, ^ref, :process, ^pid, reason} ->
        {:error, %{output: "", message: "the evaluation died: #{inspect(reason)}"}}
    after
      timeout ->
        Process.exit(pid, :kill)

        {:error,
         %{
           output: "",
           message:
             "the evaluation ran longer than #{timeout}ms and was stopped. " <>
               "Nothing it had already done was undone."
         }}
    end
  end

  defp evaluate(code, opts) do
    max_output = Keyword.fetch!(opts, :max_output)

    Process.flag(:max_heap_size, %{
      size: Keyword.fetch!(opts, :max_heap_words),
      kill: true,
      error_logger: false
    })

    # Set once per evaluation rather than per node, so an attached node is left
    # where it was found. This is a whole-VM setting, which is survivable here
    # only because this VM evaluates one thing at a time.
    case Keyword.fetch(opts, :cwd) do
      {:ok, cwd} when is_binary(cwd) -> File.cd(cwd)
      _no_cwd -> :ok
    end

    {:ok, io} = StringIO.open("")
    Process.group_leader(self(), io)

    outcome = attempt(code, max_output)

    {:ok, {_input, output}} = StringIO.close(io)

    written = cut(output, max_output)

    case outcome do
      {:ok, result} -> {:ok, %{output: written, result: result}}
      {:error, message} -> {:error, %{output: written, message: message}}
    end
  end

  # `Code.eval_string/3` and not `Code.compile_string/1`: the model is writing
  # an expression to get an answer from, not a module to keep.
  defp attempt(code, max_output) do
    {value, _binding} = Code.eval_string(code, [], file: "lmx-elixir")

    {:ok,
     cut(inspect(value, pretty: true, limit: :infinity, printable_limit: max_output), max_output)}
  rescue
    exception ->
      # Formatted here, on the node that raised it. See the @moduledoc.
      {:error, Exception.format(:error, exception, __STACKTRACE__)}
  catch
    kind, reason ->
      {:error, Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp cut(text, limit) when byte_size(text) <= limit, do: text

  defp cut(text, limit) do
    kept = binary_part(text, 0, limit)
    cut = byte_size(text) - limit

    # Sanitised because a byte-offset cut can land inside a codepoint, and
    # this has to survive being put in a JSON transcript at the other end.
    valid(kept) <> "\n\n… [#{cut} more bytes, not shown] …"
  end

  defp valid(text) do
    if String.valid?(text), do: text, else: String.replace_invalid(text)
  end
end
