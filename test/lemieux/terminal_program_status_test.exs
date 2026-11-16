defmodule Lemieux.TerminalProgramStatusTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.Terminal

  test "reports every protocol state with stable app identity and ST termination" do
    for status <- [:idle, :working, :done, :error, :clear] do
      bytes = capture_io(fn -> assert :ok = Terminal.program_status(status, :local) end)
      assert bytes == "\e]7501;state=#{status}:app=lemieux\e\\"
      assert byte_size(bytes) < 4096
    end
  end

  test "blocked kinds are structured fields rather than presentation text" do
    for kind <- [:permission, :question, :auth] do
      bytes = capture_io(fn -> Terminal.program_status({:blocked, kind}, :local) end)
      assert bytes == "\e]7501;state=blocked:kind=#{kind}:app=lemieux\e\\"
    end
  end

  test "writes to the display transport and never a cell host's own stdout" do
    owner = self()

    writer = fn bytes ->
      send(owner, {:bytes, bytes})
      :ok
    end

    assert :ok = Terminal.program_status(:working, {:session, nil, writer})
    assert_received {:bytes, "\e]7501;state=working:app=lemieux\e\\"}

    assert capture_io(fn ->
             for transport <- [:cell_session, :distributed, {:distributed, :remote}] do
               assert {:error, :unsupported_transport} = Terminal.program_status(:idle, transport)
             end
           end) == ""
  end

  test "writer failures stay best effort" do
    assert {:error, :closed} =
             Terminal.program_status(:working, {:session, nil, fn _ -> {:error, :closed} end})

    assert {:error, "closed"} =
             Terminal.program_status(:working, {:session, nil, fn _ -> raise "closed" end})
  end
end
