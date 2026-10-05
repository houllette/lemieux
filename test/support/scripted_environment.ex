defmodule LemieuxTest.ScriptedEnvironment do
  @moduledoc """
  An environment whose `run/3` replays a fixed list of command events.

  The endings a command stream can reach are the part of the environment
  contract hardest to provoke on purpose: a broken transport and a chunk that
  carried no bytes both need the local runner to misbehave. Scripting the
  events instead tests what every consumer of the contract does with them.
  """

  @behaviour Lemieux.Environment

  @impl Lemieux.Environment
  def read_file(_state, _cwd, _path), do: {:error, :enoent}

  @impl Lemieux.Environment
  def write_file(_state, _cwd, _path, _contents), do: {:error, :enotsup}

  @impl Lemieux.Environment
  def run(events, _command, _opts) when is_list(events), do: {:ok, events}
end
