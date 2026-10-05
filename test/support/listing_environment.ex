defmodule LemieuxTest.ListingEnvironment do
  @moduledoc """
  An environment that implements the optional `list_dir/3` callback.

  Deliberately referenced by nothing but `Lemieux.EnvironmentTest`, so that
  test can unload it and ask the dispatcher about a module the VM has not
  loaded yet — which is the case `function_exported?/3` alone gets wrong.
  """

  @behaviour Lemieux.Environment

  @impl Lemieux.Environment
  def read_file(_state, _cwd, _path), do: {:error, :enoent}

  @impl Lemieux.Environment
  def list_dir(_state, _cwd, path), do: {:ok, [%{name: path, type: :directory}]}

  @impl Lemieux.Environment
  def write_file(_state, _cwd, _path, _contents), do: {:error, :enotsup}

  @impl Lemieux.Environment
  def run(_state, _command, _opts), do: {:error, :enotsup}
end
