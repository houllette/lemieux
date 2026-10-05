defmodule Lemieux.Extensions.Checkpoints do
  @moduledoc """
  Records what the agent's tools change, turn by turn, so a host can offer
  undo — and records what it could not see, so undo can say so.

  Wraps `write`, `edit` and `apply_patch` (whichever the catalog has) with a
  `Lemieux.Tool.Override` whose `before` saves each target file through
  `Lemieux.Checkpoint.capture/4` and whose `after` records what the tool left,
  and adds a `user_prompt` hook that starts a new turn. With `git: true` it
  also wraps `bash` and the `elixir` evaluator: a git snapshot of the working
  directory immediately before each call and immediately after it, so what a
  command changed can be undone too (see `Lemieux.Checkpoint.Git`). A call
  that is cancelled or times out is killed before its own after-snapshot can
  run, so the wrapper asks `Lemieux.Checkpoint.snapshot/4` to watch the tool
  task and take it when the task exits.

  ## What it records as unrecorded

  An undo that answers "nothing to undo" after a command deleted a file has
  told the person something false. So whatever this sees run and cannot
  record is noted with the turn (`Lemieux.Checkpoint.mark_unrecorded/4`) and
  undo reports it:

    * a command in a working directory that is not a git repository, or
      that its repository ignores, or whose snapshot failed;
    * a command started in the background — what it changes after its call
      returns falls outside any snapshot;
    * a call to an MCP server's tool, whose effects are out of sight
      entirely. It is noted when the call returns; one cancelled mid-call
      is not. A server's `readOnlyHint` is not believed here any more than
      elsewhere (`Lemieux.Tool.read_only?/1`): it costs nothing to claim,
      and believing a wrong one is an undo that says nothing about a write.

  Without `git: true` only the file tools are recorded and nothing is noted:
  such a host has chosen an undo that covers the file tools alone.

  Not seen at all, so neither recorded nor noted: background commands' later
  effects beyond the note, hooks other than through the file tools' own
  after-records (below), tools added to the catalog after this extension
  applied, and a host's own tools. The check `Lemieux.Extensions.Verify`
  runs after a turn goes through the environment, not through a wrapped
  tool, and so is not wrapped here; given `:checkpoints` — the directory
  given here as `:dir`, which `lmx` passes it — it brackets itself with
  `Lemieux.Checkpoint.around/4` and is recorded like a command.

  ## Git on this machine

  The snapshots run git on this machine, outside a sandbox the commands run
  in, in a repository they can write. They run it in a git directory of
  their own, made under `:dir`, so that nothing the repository configures —
  a hook, `core.fsmonitor`, a filter driver a command wrote into
  `.git/config` — runs here (`Lemieux.Checkpoint.Git`). `:dir` must
  therefore be out of the commands' reach; `lmx`'s is in `~/.lmx`, which
  `--sandbox` hides.

  ## Hooks that rewrite what the agent wrote

  A formatter run from a post-tool hook changes the file the agent just
  wrote, after the wrapper recorded what the tool left; undo would then call
  the file "changed since the agent wrote it" and leave it. So this also
  adds an `after_tool_call` hook that records the file tools' targets again,
  once the hooks registered before it have run. Hooks registered after this
  extension applied are not covered.

  ## Never refusing

  Recording never refuses a call: refusing the edit because its checkpoint
  could not be written would turn a safety net into an outage. What that
  costs is said where it can be. A pre-image whose contents could not be
  stored is recorded as such, and undo names the file as unrestorable; a
  store that could not be written at all leaves nothing, and undo says the
  store is unwritable rather than "nothing to undo". A snapshot that cannot
  be taken — no git, no temporary directory for its private index — is
  noted, so undo names the command; a file name that is not UTF-8 is
  recorded as its bytes (`Lemieux.Checkpoint.Store`), where it once failed
  every command in its repository. A store that fails partway through a
  turn — a disk filling up — can leave a change unrecorded that undo cannot
  name.

  Apply it after the extensions that fill or swap the catalog — after
  `Lemieux.Extensions.ApplyPatch`, which replaces `edit` — because it wraps
  the tools that are there when it runs.

  Options:

    * `:dir` (required) — where checkpoints are kept; `lmx` uses
      `~/.lmx/checkpoints`.
    * `:git` — also snapshot around `bash` and `elixir`, and note what
      commands it cannot record. Defaults to `false`.
    * `:max_file_bytes` — the largest file whose contents are saved.
      Defaults to 10 MB.
    * `:tools` — the file tools to wrap. Defaults to `write`, `edit` and
      `apply_patch`.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Checkpoint
  alias Lemieux.Harness
  alias Lemieux.Tool
  alias Lemieux.Tool.Override
  alias Lemieux.Tools.ApplyPatch

  @file_tools ["write", "edit", "apply_patch"]
  @command_tools ["bash", "elixir"]
  @digest "lemieux-checkpoints-v2"

  @impl Lemieux.Extension
  def init(opts) do
    with {:ok, dir} <- dir(Keyword.get(opts, :dir)),
         {:ok, tools} <- tools(Keyword.get(opts, :tools, @file_tools)) do
      {:ok,
       %{
         dir: dir,
         git: Keyword.get(opts, :git, false) == true,
         max_file_bytes: Keyword.get(opts, :max_file_bytes, 10_000_000),
         tools: tools
       }}
    end
  end

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, state) do
    harness
    |> Harness.update_tools(&decorate(&1, state))
    |> Harness.append_hooks(user_prompt: begin_turn(state), after_tool_call: after_call(state))
  end

  @impl Lemieux.Extension
  def describe(state) do
    %{"dir" => state.dir, "git" => state.git, "tools" => state.tools}
  end

  defp dir(dir) when is_binary(dir) and dir != "", do: {:ok, Path.expand(dir)}
  defp dir(_dir), do: {:error, "Lemieux.Extensions.Checkpoints needs :dir, a directory path"}

  defp tools(tools) when is_list(tools) do
    if Enum.all?(tools, &is_binary/1),
      do: {:ok, tools},
      else: {:error, ":tools must be a list of tool names"}
  end

  defp tools(_tools), do: {:error, ":tools must be a list of tool names"}

  defp begin_turn(state) do
    fn _prompt, context ->
      _ = Checkpoint.begin_turn(state.dir, context.session_id)
      :allow
    end
  end

  # After every call, whatever the tool: the file tools' targets are recorded
  # again, past the hooks that ran before this one; an MCP tool is noted as
  # unrecorded. Feedback is never returned — this observes.
  defp after_call(state) do
    fn call, _result, context ->
      _ = observe(call, context, state)
      :ok
    end
  end

  defp observe(%{name: name} = call, context, state) do
    cond do
      name in state.tools ->
        for path <- paths(name, call.arguments || %{}),
            do: Checkpoint.record_after(state.dir, context, path)

      state.git and mcp?(context) ->
        Checkpoint.mark_unrecorded(
          state.dir,
          context,
          name,
          "an MCP server's tool, whose effects undo cannot see or record"
        )

      true ->
        :ok
    end
  end

  defp mcp?(%{tool_descriptor: %{"origin" => %{"type" => "mcp"}}}), do: true
  defp mcp?(_context), do: false

  defp decorate(tools, state) do
    present = MapSet.new(tools, &Tool.name/1)
    wanted = if state.git, do: @command_tools ++ state.tools, else: state.tools

    wrappers =
      for name <- wanted, MapSet.member?(present, name), into: %{} do
        {name, &wrap(&1, name, state)}
      end

    Tool.decorate(tools, wrappers)
  end

  defp wrap(tool, name, state) when name in @command_tools do
    Override.new!(tool,
      digest: @digest,
      before: fn args, context ->
        subject = subject(name, args)

        _ =
          Checkpoint.snapshot(state.dir, context, :before,
            watch: self(),
            subject: subject
          )

        if args["background"] == true do
          Checkpoint.mark_unrecorded(
            state.dir,
            context,
            subject,
            "it runs in the background, so what it changes after its call returns is not recorded"
          )
        end

        {:ok, args}
      end,
      after: fn return, _args, context -> after_command(return, context, state) end
    )
  end

  defp wrap(tool, name, state) do
    Override.new!(tool,
      digest: @digest,
      before: fn args, context ->
        for path <- paths(name, args) do
          Checkpoint.capture(state.dir, context, path,
            tool: name,
            max_file_bytes: state.max_file_bytes
          )
        end

        {:ok, args}
      end,
      after: fn return, args, context ->
        for path <- paths(name, args), do: Checkpoint.record_after(state.dir, context, path)
        return
      end
    )
  end

  # The command may still be running when a stream comes back, and the files it
  # changes are what the after-snapshot is for; so the snapshot waits until the
  # stream has ended, whether it ran out or its consumer stopped. A consumer
  # that is killed never gets here; the watcher `snapshot/4` started does.
  defp after_command({:stream, enumerable}, context, state) do
    {:stream,
     Stream.transform(
       enumerable,
       fn -> :ok end,
       fn item, acc -> {[item], acc} end,
       fn _acc -> Checkpoint.snapshot(state.dir, context, :after) end
     )}
  end

  defp after_command(return, context, state) do
    _ = Checkpoint.snapshot(state.dir, context, :after)
    return
  end

  defp subject("bash", %{"command" => command}) when is_binary(command),
    do: Checkpoint.subject(command)

  defp subject("bash", %{"task_id" => task_id}) when is_binary(task_id),
    do: "the background task #{task_id}"

  defp subject("elixir", %{"code" => code}) when is_binary(code),
    do: "the elixir tool's " <> Checkpoint.subject(code)

  defp subject(name, _args), do: "the #{name} tool"

  defp paths("apply_patch", %{"input" => input}) do
    case ApplyPatch.paths(input) do
      {:ok, paths} -> paths
      {:error, _reason} -> []
    end
  end

  defp paths("apply_patch", %{"patch" => input}), do: paths("apply_patch", %{"input" => input})
  defp paths(_name, %{"path" => path}) when is_binary(path), do: [path]
  defp paths(_name, _args), do: []
end
