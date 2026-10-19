defmodule Lemieux.CLI.Learning.Container do
  @moduledoc false
  @behaviour Lemieux.Environment
  alias Lemieux.Agent.Resource
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox

  @spec new(image :: String.t()) :: {:ok, Lemieux.Environment.t()} | {:error, term()}
  def new(image) do
    case System.cmd("docker", ["image", "inspect", image, "--format", "{{.Id}}"],
           stderr_to_stdout: true
         ) do
      {"sha256:" <> _ = id, 0} ->
        {uid, 0} = System.cmd("id", ["-u"])
        {gid, 0} = System.cmd("id", ["-g"])

        {:ok,
         {__MODULE__,
          %{image: String.trim(id), user: String.trim(uid) <> ":" <> String.trim(gid)}}}

      _unavailable ->
        {:error, :qualification_image_unavailable}
    end
  end

  @impl true
  def read_file(_state, cwd, path), do: Local.read_file(nil, cwd, path)
  @impl true
  def stream_file(_state, cwd, path), do: Local.stream_file(nil, cwd, path)
  @impl true
  def list_dir(_state, cwd, path), do: Local.list_dir(nil, cwd, path)
  @impl true
  def write_file(_state, cwd, path, bytes), do: Local.write_file(nil, cwd, path, bytes)
  @impl true
  def delete_file(_state, cwd, path), do: Local.delete_file(nil, cwd, path)
  @impl true
  def credentials(_state), do: {:scrub, []}

  # Each command gets a fresh unprivileged container with only its workspace
  # mounted. No host home, socket, token, grader, other arm or network is visible.
  # The guardian owns the container before it starts and removes its entire
  # process tree if the stream consumer is killed, even before enumeration.
  @impl true
  def run(state, command, opts) do
    events = Stream.resource(fn -> start(state, command, opts) end, &next/1, &finish/1)
    {:ok, events}
  end

  defp start(state, command, opts) do
    name = "lmx-qual-" <> String.downcase(Lemieux.ID.generate())
    cwd = Path.expand(Keyword.fetch!(opts, :cwd))

    args = [
      "create",
      "--name",
      name,
      "--user",
      state.user,
      "--label",
      "lemieux.learning.qualification=true",
      "--network",
      "none",
      "--read-only",
      "--cap-drop",
      "ALL",
      "--security-opt",
      "no-new-privileges",
      "--pids-limit",
      "128",
      "--memory",
      "512m",
      "--cpus",
      "1",
      "--tmpfs",
      "/tmp:rw,nosuid,size=64m",
      "--volume",
      cwd <> ":/workspace:rw",
      "--workdir",
      "/workspace",
      state.image,
      "sh",
      "-c",
      "ulimit -f 4096; " <> command
    ]

    {:ok, id, guardian} =
      Resource.acquire(
        fn _ ->
          case System.cmd("docker", args, stderr_to_stdout: true) do
            {_output, 0} -> {:ok, name}
            _error -> {:error, :container_create_failed}
          end
        end,
        &remove/1,
        abort: fn -> remove(name) end
      )

    try do
      start = "exec docker start --attach --interactive " <> Sandbox.quote_shell(id)
      {_module, client} = Local.new(credentials: {:scrub, []})
      {:ok, events} = Local.run(client, start, Keyword.put(opts, :cwd, System.tmp_dir!()))

      continuation = fn accumulator ->
        Enumerable.reduce(events, accumulator, fn event, _ -> {:suspend, event} end)
      end

      {continuation, guardian}
    rescue
      error ->
        Resource.release(guardian)
        reraise(error, __STACKTRACE__)
    end
  end

  defp next({continuation, guardian} = state) do
    case continuation.({:cont, nil}) do
      {:suspended, event, next} -> {[event], {next, guardian}}
      {:done, _} -> {:halt, state}
      {:halted, _} -> {:halt, state}
    end
  end

  defp finish({continuation, guardian}) do
    continuation.({:halt, nil})
    :ok = Resource.release(guardian)
  end

  defp remove(id) do
    case System.cmd("docker", ["rm", "--force", id], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {message, _} ->
        if String.contains?(message, "No such container"),
          do: :ok,
          else: {:error, :container_cleanup_failed}
    end
  end
end
