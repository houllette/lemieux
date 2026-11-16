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

  test "optional titles are base64 UTF-8 single-line labels within the protocol byte limit" do
    title = "Review: 日本!\n\t\e\u009b" <> String.duplicate("é", 120)
    bytes = capture_io(fn -> Terminal.program_status(:working, :local, title: title) end)
    assert "\e]7501;state=working:app=lemieux:title=" <> encoded = bytes
    assert String.ends_with?(encoded, "\e\\")
    decoded = encoded |> String.trim_trailing("\e\\") |> Base.decode64!()
    assert String.starts_with?(decoded, "Review: 日本!")
    assert String.valid?(decoded)
    assert byte_size(decoded) <= 192
    refute decoded =~ ~r/[\x{00}-\x{1f}\x{7f}-\x{9f}]/u
    assert byte_size(bytes) < 4096

    invalid =
      capture_io(fn -> Terminal.program_status(:idle, :local, title: <<"a", 255, "b">>) end)

    assert invalid == "\e]7501;state=idle:app=lemieux:title=" <> Base.encode64("a�b") <> "\e\\"

    clear = capture_io(fn -> Terminal.program_status(:clear, :local, title: "Caption") end)
    assert clear == "\e]7501;state=clear:app=lemieux\e\\"
  end
end
