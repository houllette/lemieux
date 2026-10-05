defmodule Lemieux.Environment.LocalKillFallbackTest do
  # Debian-based images — the hexpm/elixir `-slim` ones, Phoenix's generated
  # release image — have no `kill` executable. A timed-out command's children
  # used to run on there, while the teardown skipped the signal in silence.
  #
  # Not async: these point the whole VM's PATH at a directory without `kill`,
  # which every concurrently running command would see.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Lemieux.Environment.Local.ExCmd

  @moduletag :tmp_dir

  unless match?({:unix, _}, :os.type()) and ExCmd.process_groups?() do
    @moduletag skip: "needs process groups: setsid or perl, and kill or sh"
  end

  # What a command needs from PATH here, less `kill`: the shells, what starts
  # a session (setsid on Linux, perl on macOS), `ps` where there is no /proc,
  # and the command's own `sleep`.
  @tools ~w(sh bash setsid perl ps sleep)

  setup %{tmp_dir: tmp_dir} do
    path = System.get_env("PATH")
    on_exit(fn -> System.put_env("PATH", path) end)

    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)
    %{bin: bin, work: tmp_dir}
  end

  defp link_tools(bin, tools) do
    for tool <- tools, source = System.find_executable(tool), source != nil do
      File.ln_s!(source, Path.join(bin, tool))
    end

    System.put_env("PATH", bin)
  end

  test "a timeout stops the command's children with the shell's own kill", context do
    link_tools(context.bin, @tools)
    assert System.find_executable("kill") == nil
    assert ExCmd.process_groups?()

    log =
      capture_log(fn ->
        {:ok, events} =
          ExCmd.run("sleep 30 & echo $! > child.pid; wait",
            cwd: context.work,
            timeout_ms: 3_000,
            max_output_bytes: 1_000_000
          )

        assert List.last(Enum.to_list(events)) == {:timeout, 3_000}
      end)

    child = context.work |> Path.join("child.pid") |> File.read!() |> String.trim()
    assert gone?(child), "the command's child #{child} outlived its timeout"
    refute log =~ "could not kill process group"
  end

  test "without kill or a shell to signal with, commands get no group to promise", context do
    link_tools(context.bin, ~w(setsid perl))
    assert System.find_executable("kill") == nil
    assert System.find_executable("sh") == nil

    refute ExCmd.process_groups?()
  end

  defp alive?(pid),
    do: match?({_output, 0}, System.cmd("/bin/sh", ["-c", "kill -0 #{pid} 2>/dev/null"]))

  defp gone?(pid, attempts \\ 100)
  defp gone?(pid, 0), do: not alive?(pid)

  defp gone?(pid, attempts) do
    if alive?(pid) do
      Process.sleep(50)
      gone?(pid, attempts - 1)
    else
      true
    end
  end
end
