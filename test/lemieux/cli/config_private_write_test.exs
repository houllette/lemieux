defmodule Lemieux.CLI.ConfigPrivateWriteTest do
  # `Lemieux.CLI.Config.update/2` wrote the whole config, provider keys and
  # all, into its temporary file at the process umask's mode (0644 under the
  # usual 022) and only then made it 0600: in a `--config` directory others
  # can list, the keys were readable for that moment (found in review,
  # 2026-10). The order of the calls that reach the file system is the whole
  # property, and a moment too short to catch by looking, so the test traces
  # them: every call into `:file` this process makes, which is where `File`
  # and `IO` end up.
  use ExUnit.Case, async: true

  alias Lemieux.CLI.Config

  @moduletag :tmp_dir

  defp file_calls(fun) do
    collector = spawn_link(fn -> collect([]) end)
    session = :trace.session_create(__MODULE__, collector, [])

    try do
      1 = :trace.process(session, self(), true, [:call])
      _ = :trace.function(session, {:file, :_, :_}, true, [])
      fun.()
    after
      :trace.session_destroy(session)
    end

    send(collector, {:calls, self()})

    receive do
      {:calls, calls} -> calls
    after
      5_000 -> flunk("the trace collector did not answer")
    end
  end

  defp collect(calls) do
    receive do
      {:trace, _pid, :call, {:file, function, arguments}} ->
        collect([{function, arguments} | calls])

      {:calls, from} ->
        send(from, {:calls, Enum.reverse(calls)})
    end
  end

  defp carries?({_function, arguments}, secret),
    do: inspect(arguments, limit: :infinity, printable_limit: :infinity) =~ secret

  test "a saved key is written only into a file that is already private", %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    key = "sk-test-#{System.unique_integer([:positive])}"

    calls = file_calls(fn -> assert :ok = Config.put_provider_key(path, "openai", key) end)

    written = Enum.find_index(calls, &carries?(&1, key))
    private = Enum.find_index(calls, &match?({:change_mode, [_temporary, 0o600]}, &1))

    assert written, "no call wrote the key: #{inspect(calls)}"
    assert private, "nothing made the temporary file 0600: #{inspect(calls)}"
    assert private < written, "the key was written before the file was private"

    assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    assert JSON.decode!(File.read!(path))["providers"]["openai"]["api_key"] == key
  end
end
