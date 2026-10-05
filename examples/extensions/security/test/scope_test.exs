defmodule SecurityExample.ScopeTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.Extension.Profile
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL
  alias SecurityExample.Scope

  @moduletag :tmp_dir

  # Records every command instead of running it, so no test ever scans.
  defmodule RecordingEnvironment do
    @behaviour Lemieux.Environment

    @impl true
    def read_file(_owner, _cwd, _path), do: {:error, :enoent}

    @impl true
    def write_file(_owner, _cwd, _path, _contents), do: {:error, :eacces}

    @impl true
    def run(owner, command, _opts) do
      send(owner, {:ran, command})
      {:ok, [{:data, "<nmaprun></nmaprun>"}, {:exit_status, 0}]}
    end
  end

  defp scan(target), do: %{name: "nmap_scan", arguments: %{"target" => target, "ports" => [22]}}

  describe "decide/3" do
    setup do
      {:ok, allowed} = Scope.init(scan_targets: ["127.0.0.1", "192.0.2.10"])
      %{allowed: allowed}
    end

    test "allows a listed target", %{allowed: allowed} do
      assert Scope.decide(scan("192.0.2.10"), allowed) == :allow
    end

    test "denies any other target, telling the model what is in scope", %{allowed: allowed} do
      assert {:deny, reason} = Scope.decide(scan("192.0.2.11"), allowed)
      assert reason =~ "192.0.2.11 is not an authorized scan target"
      assert reason =~ "The authorized targets are 127.0.0.1, 192.0.2.10"
    end

    test "denies a target that is not one IPv4 address", %{allowed: allowed} do
      for target <- ["127.0.0.1/8", "localhost", "127.1", "::1"] do
        assert {:deny, _reason} = Scope.decide(scan(target), allowed), target
      end

      assert {:deny, _reason} = Scope.decide(%{name: "nmap_scan", arguments: %{}}, allowed)
    end

    test "leaves every other tool to the host's policy", %{allowed: allowed} do
      call = %{name: "assess_ports", arguments: %{"ports" => [23]}}
      assert Scope.decide(call, allowed) == :allow
    end
  end

  test "with nothing configured, nothing may be scanned" do
    assert {:ok, allowed} = Scope.init(scan_targets: [])
    assert {:deny, reason} = Scope.decide(scan("127.0.0.1"), allowed)
    assert reason =~ "No scan targets are configured"
  end

  test "a target that is not one IPv4 address is refused when the scope is built" do
    assert {:error, message} = Scope.init(scan_targets: ["192.0.2.0/24"])
    assert message =~ ~s("192.0.2.0/24" is not one IPv4 address)

    assert_raise ArgumentError, ~r/example.com/, fn -> Scope.hooks(["example.com"]) end
  end

  test "configure/2 reports unusable targets as an error instead of raising" do
    assert {:error, {Scope, message}} =
             SecurityExample.configure(profile(), scan_targets: ["192.0.2.0/24"])

    assert message =~ ~s("192.0.2.0/24" is not one IPv4 address)
  end

  test "an agent run denies an out-of-scope scan before Nmap runs", %{tmp_dir: dir} do
    provider = Scripted.new(two_scans_then_report())

    {:ok, opts, _profile} =
      SecurityExample.configure(profile(),
        provider: provider,
        scan_targets: ["127.0.0.1"],
        environment: {RecordingEnvironment, self()},
        supervisor: :"security_scope_#{System.unique_integer([:positive])}",
        sessions_dir: Path.join(dir, "sessions")
      )

    input = %{prompt: "scan", cwd: dir, timeout_ms: 15_000}
    assert {:ok, observation} = Lemieux.Agent.run(SecurityExample, input, opts)

    assert [denied, ran] = JSON.decode!(observation["answer"])
    assert denied =~ "192.0.2.1 is not an authorized scan target"
    assert ran =~ "<nmaprun>"

    assert_received {:ran, "nmap -sT -n --host-timeout 20s -p 22 -oX - 127.0.0.1"}
    refute_received {:ran, _other}
  end

  test "the example's CLI applies the same scope", %{tmp_dir: dir} do
    provider = Scripted.new(two_scans_then_report())

    capture_io(:stderr, fn ->
      capture_io(fn ->
        assert :ok =
                 SecurityExample.cli(["run", "scan"],
                   profile: profile(),
                   provider: provider,
                   scan_targets: ["127.0.0.1"],
                   environment: {RecordingEnvironment, self()},
                   supervisor: :"security_scope_cli_#{System.unique_integer([:positive])}",
                   store: JSONL.new(Path.join(dir, "sessions")),
                   cwd: dir,
                   stdin_terminal?: true
                 )
      end)
    end)

    assert_received {:ran, "nmap -sT -n --host-timeout 20s -p 22 -oX - 127.0.0.1"}
    refute_received {:ran, _other}

    outputs = provider |> Scripted.requests() |> List.last() |> tool_outputs()
    assert Enum.any?(outputs, &(&1 =~ "192.0.2.1 is not an authorized scan target"))
  end

  # Host hooks replace the hooks a CLI session assembled; the scope must
  # come back with them rather than disappear.
  test "explicit host hooks do not lift the scope", %{tmp_dir: dir} do
    provider = Scripted.new(two_scans_then_report())
    host = [before_tool_call: fn _call, _context -> :allow end]

    capture_io(:stderr, fn ->
      capture_io(fn ->
        assert :ok =
                 SecurityExample.cli(["run", "scan"],
                   profile: profile(),
                   provider: provider,
                   hooks: host,
                   scan_targets: ["127.0.0.1"],
                   environment: {RecordingEnvironment, self()},
                   supervisor: :"security_scope_hooks_#{System.unique_integer([:positive])}",
                   store: JSONL.new(Path.join(dir, "sessions")),
                   cwd: dir,
                   stdin_terminal?: true
                 )
      end)
    end)

    assert_received {:ran, "nmap -sT -n --host-timeout 20s -p 22 -oX - 127.0.0.1"}
    refute_received {:ran, "nmap -sT -n --host-timeout 20s -p 22 -oX - 192.0.2.1"}
  end

  # A request bound rather than a dollar cap: the scripted provider has no
  # prices, and a dollar cap with unknown prices refuses to send.
  defp profile, do: "test:model" |> SecurityExample.profile() |> Profile.quota(4)

  # Scans an out-of-scope address, then a listed one, then answers with the
  # two tool results it was shown, in order.
  defp two_scans_then_report do
    [
      Scripted.tool_call("out", "nmap_scan", %{"target" => "192.0.2.1", "ports" => [22]}),
      Scripted.tool_call("in", "nmap_scan", %{"target" => "127.0.0.1", "ports" => [22]}),
      fn request -> Scripted.complete(JSON.encode!(tool_outputs(request))) end
    ]
  end

  defp tool_outputs(request) do
    for %{type: :tool_result, payload: payload} <- request.entries, do: payload["output"]
  end
end
