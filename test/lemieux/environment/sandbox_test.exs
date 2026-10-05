defmodule Lemieux.Environment.SandboxTest do
  use ExUnit.Case, async: true

  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Environment.Sandbox.Bubblewrap
  alias Lemieux.Environment.Sandbox.Seatbelt

  @moduletag :tmp_dir

  @seatbelt? :os.type() == {:unix, :darwin} and System.find_executable("sandbox-exec") != nil
  @bubblewrap? :os.type() == {:unix, :linux} and System.find_executable("bwrap") != nil

  # CI's Linux sandbox job installs bubblewrap, allows unprivileged user
  # namespaces and sets LMX_REQUIRE_SANDBOX=1. There a missing `bwrap`, or one
  # that cannot start a sandbox, fails the run: before the flag, the only test
  # that ran a command under bubblewrap was skipped without `bwrap` and passed
  # on the construction error without it working, so the Linux sandbox was
  # never exercised anywhere. Without the flag both stay a skip or a pass,
  # because a contributor's machine may have neither.
  # On macOS the flag requires Seatbelt in the same way.
  @require_sandbox? System.get_env("LMX_REQUIRE_SANDBOX") == "1"
  @run_seatbelt? @seatbelt? or (@require_sandbox? and :os.type() == {:unix, :darwin})
  @run_bubblewrap? @bubblewrap? or (@require_sandbox? and :os.type() == {:unix, :linux})

  # Both sandboxes let every command write to the temporary directories (and a
  # few caches), on purpose: compilers and package managers need them. A test's
  # tmp_dir is inside the checkout, so in a checkout under one of those — a
  # clone in /tmp — the "outside" file the refusal tests write is inside a
  # writable root, and the sandbox is right to allow it. Those tests failed on
  # every run there and passed everywhere else. Read from the sandbox's own
  # policy rather than restated, so the skip follows the policy if it changes.
  # The tag is set only when it applies: a test's `skip: false` would override
  # its describe block's skip, and run the Seatbelt test on Linux.
  @writable_by_default (case Sandbox.new(probe: false) do
                          {:ok, environment} -> Sandbox.describe(environment)["writable"]
                          {:error, _no_sandbox} -> []
                        end)
  # A variable, not an attribute: it is read only inside the function, which
  # never runs when no sandbox exists (Linux without bubblewrap), and an
  # attribute nobody read failed `--warnings-as-errors` there (CI, 2026-10-05).
  checkout = Sandbox.real(File.cwd!()) <> "/"
  @writable_root Enum.find(@writable_by_default, &String.starts_with?(checkout, &1 <> "/"))
  @checkout_writable @writable_root &&
                       "the checkout is under #{@writable_root}, which the sandbox leaves " <>
                         "writable, so nothing in it is outside the sandbox"

  defp sandbox(backend, attrs \\ []) do
    struct!(
      %Sandbox{
        backend: backend,
        executable: "/usr/bin/#{if backend == :seatbelt, do: "sandbox-exec", else: "bwrap"}",
        inner: Local,
        shell: "/bin/bash"
      },
      attrs
    )
  end

  # Runs `command` through `environment` and returns everything it said and
  # how it ended, the way the bash tool consumes the same stream.
  defp run(environment, command, cwd) do
    {:ok, events} = Environment.run(environment, command, cwd: cwd, timeout_ms: 20_000)

    Enum.reduce(events, {"", nil}, fn
      {:data, data}, {output, status} -> {output <> data, status}
      {:exit_status, status}, {output, _status} -> {output, status}
      other, {output, _status} -> {output, other}
    end)
  end

  describe "availability" do
    test "an unknown backend is refused, and bubblewrap is found only where it exists" do
      assert {:error, _reason} = Sandbox.available(:jail)

      case System.find_executable("bwrap") do
        nil ->
          assert {:error, message} = Sandbox.available(:bubblewrap)
          assert message =~ "bubblewrap"
          assert {:error, ^message} = Sandbox.new(backend: :bubblewrap)

        path ->
          assert {:ok, :bubblewrap, ^path} = Sandbox.available(:bubblewrap)
      end
    end
  end

  describe "what counts as sandboxed" do
    defmodule Jail do
      @moduledoc false
      def sandboxed?(_state), do: true
    end

    test "the sandbox environment and any environment that says so" do
      assert Sandbox.sandboxed?({Sandbox, sandbox(:seatbelt)})
      assert Sandbox.sandboxed?({Jail, :anything})
      refute Sandbox.sandboxed?(Local)
      refute Sandbox.sandboxed?(Local.new())
      refute Sandbox.sandboxed?(nil)
    end

    test "describe/1 reports the policy, and nothing for an ordinary environment" do
      assert %{"backend" => "seatbelt", "network" => false, "localhost" => true} =
               Sandbox.describe({Sandbox, sandbox(:seatbelt)})

      assert Sandbox.describe(Local) == nil
    end
  end

  describe "the Seatbelt profile" do
    test "denies writes outside the roots, the network apart from loopback, and hidden paths" do
      profile =
        Seatbelt.profile(
          sandbox(:seatbelt, writable: ["/cache"], hidden: ["/home/me/.ssh"]),
          "/work"
        )

      assert profile =~ "(deny file-write*)"
      assert profile =~ ~s|(subpath "/work")|
      assert profile =~ ~s|(subpath "/cache")|
      assert profile =~ "(deny network*)"
      assert profile =~ ~s|(allow network-outbound (remote ip "localhost:*"))|
      assert profile =~ ~s|(deny file-read* file-write*\n  (subpath "/home/me/.ssh"))|

      # The hidden paths are denied after the roots, because the last rule wins.
      assert :binary.match(profile, ~s|(subpath "/work")|) <
               :binary.match(profile, "/home/me/.ssh")
    end

    test "loopback can be closed too, and the network opened entirely" do
      closed = Seatbelt.profile(sandbox(:seatbelt, localhost: false), "/work")
      open = Seatbelt.profile(sandbox(:seatbelt, network: true), "/work")

      assert closed =~ "(deny network*)"
      refute closed =~ "localhost"
      refute open =~ "network"
    end

    test "quotes in paths cannot break out of the profile's strings" do
      profile = Seatbelt.profile(sandbox(:seatbelt), ~s(/work/a"b))
      assert profile =~ ~s|(subpath "/work/a\\"b")|
    end
  end

  describe "the bubblewrap command line" do
    test "binds the root read-only, the roots read-write, hides credentials and unshares the net",
         %{tmp_dir: tmp_dir} do
      hidden_dir = Path.join(tmp_dir, ".ssh")
      hidden_file = Path.join(tmp_dir, ".netrc")
      File.mkdir_p!(hidden_dir)
      File.write!(hidden_file, "")

      sandbox = sandbox(:bubblewrap, writable: ["/tmp"], hidden: [hidden_dir, hidden_file])
      arguments = Bubblewrap.arguments(sandbox, "/work", "make test")
      real_work = Sandbox.real("/work")

      assert ["--die-with-parent", "--unshare-pid", "--new-session" | _rest] = arguments

      assert Enum.take(arguments, -6) == [
               "--chdir",
               real_work,
               "--",
               "/bin/bash",
               "-c",
               "make test"
             ]

      assert sequence?(arguments, ["--ro-bind", "/", "/"])
      assert sequence?(arguments, ["--bind", real_work, real_work])
      assert sequence?(arguments, ["--bind", "/tmp", "/tmp"])
      assert sequence?(arguments, ["--tmpfs", hidden_dir])
      assert sequence?(arguments, ["--ro-bind", "/dev/null", hidden_file])
      assert "--unshare-net" in arguments

      refute "--unshare-net" in Bubblewrap.arguments(%{sandbox | network: true}, "/work", "x")
    end

    test "the wrapped command survives quoting" do
      wrapped = Sandbox.wrap(sandbox(:bubblewrap), "echo 'it''s'", "/work")
      assert String.starts_with?(wrapped, "exec '/usr/bin/bwrap'")
      assert wrapped =~ ~S|'echo '\''it'\'''\''s'\'''|
    end
  end

  describe "files" do
    test "go through the wrapped environment and keep its confinement", %{tmp_dir: tmp_dir} do
      environment = {Sandbox, sandbox(:seatbelt)}

      assert {:ok, :created} = Environment.write_file(environment, tmp_dir, "a.txt", "hello")
      assert {:ok, "hello"} = Environment.read_file(environment, tmp_dir, "a.txt")

      assert {:error, :outside_worktree} =
               Environment.write_file(environment, tmp_dir, "../x", "no")
    end

    test "the credential policy is the wrapped environment's" do
      scrubbing = sandbox(:seatbelt, inner: Local.new(credentials: true))

      assert Environment.credentials({Sandbox, scrubbing}) == {:scrub, []}
      assert Environment.credentials({Sandbox, sandbox(:seatbelt)}) == :inherit
    end
  end

  describe "running under Seatbelt" do
    unless @run_seatbelt?, do: @describetag(skip: "requires macOS sandbox-exec")

    setup %{tmp_dir: tmp_dir} do
      work = Path.join(tmp_dir, "work")
      File.mkdir_p!(work)
      secret = Path.join(tmp_dir, "secret")
      File.mkdir_p!(secret)
      File.write!(Path.join(secret, "key"), "s3cret")

      {:ok, environment} = Sandbox.new(hidden: [secret])
      %{work: work, secret: secret, environment: environment}
    end

    if @checkout_writable, do: @tag(skip: @checkout_writable)

    test "writes inside the directory, and is refused outside it", context do
      assert {_output, 0} = run(context.environment, "echo hi > inside.txt", context.work)
      assert File.read!(Path.join(context.work, "inside.txt")) == "hi\n"

      outside = Path.join(context.tmp_dir, "outside.txt")
      assert {output, status} = run(context.environment, "echo no > '#{outside}'", context.work)
      assert status != 0
      assert output =~ "Operation not permitted"
      refute File.exists?(outside)
    end

    test "hidden paths cannot be read", context do
      assert {output, status} =
               run(context.environment, "cat '#{context.secret}/key'", context.work)

      assert status != 0
      refute output =~ "s3cret"
    end

    test "loopback is reachable unless it is closed too", context do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(listener)
      connect = "exec 3<>/dev/tcp/127.0.0.1/#{port} && echo connected"

      try do
        assert {"connected\n", 0} = run(context.environment, connect, context.work)

        {:ok, closed} = Sandbox.new(localhost: false)
        assert {output, status} = run(closed, connect, context.work)
        assert status != 0
        refute output =~ "connected"
      after
        :gen_tcp.close(listener)
      end
    end
  end

  describe "running under bubblewrap" do
    unless @run_bubblewrap?, do: @describetag(skip: "requires Linux bubblewrap")

    setup %{tmp_dir: tmp_dir} do
      work = Path.join(tmp_dir, "work")
      File.mkdir_p!(work)
      secret = Path.join(tmp_dir, "secret")
      File.mkdir_p!(secret)
      File.write!(Path.join(secret, "key"), "s3cret")

      %{work: work, secret: secret, started: Sandbox.new(hidden: [secret])}
    end

    if @checkout_writable, do: @tag(skip: @checkout_writable)

    test "writes inside the directory, and is refused outside it", context do
      with_bubblewrap(context.started, fn environment ->
        assert {_output, 0} = run(environment, "echo hi > inside.txt", context.work)
        assert File.read!(Path.join(context.work, "inside.txt")) == "hi\n"

        outside = Path.join(context.tmp_dir, "outside.txt")
        assert {_output, status} = run(environment, "echo no > '#{outside}'", context.work)
        assert status != 0
        refute File.exists?(outside)
      end)
    end

    test "hidden paths cannot be read", context do
      with_bubblewrap(context.started, fn environment ->
        assert {output, status} = run(environment, "cat '#{context.secret}/key'", context.work)

        assert status != 0
        refute output =~ "s3cret"
      end)
    end

    # Unlike Seatbelt, bubblewrap cannot let the host's loopback through
    # without leaving the host's network namespace (`Bubblewrap`'s moduledoc),
    # so a host service is out of reach whether loopback is allowed or not.
    test "the host's loopback is out of reach, with or without localhost", context do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
      {:ok, port} = :inet.port(listener)
      connect = "exec 3<>/dev/tcp/127.0.0.1/#{port} && echo connected"

      try do
        with_bubblewrap(context.started, fn environment ->
          assert {output, status} = run(environment, connect, context.work)
          assert status != 0
          refute output =~ "connected"
        end)

        with_bubblewrap(Sandbox.new(localhost: false), fn closed ->
          assert {output, status} = run(closed, connect, context.work)
          assert status != 0
          refute output =~ "connected"
        end)
      after
        :gen_tcp.close(listener)
      end
    end
  end

  # Runs `fun` in a sandbox that started. One that did not is a failure under
  # LMX_REQUIRE_SANDBOX=1, whatever the reason (no `bwrap`, or user namespaces
  # forbidden); elsewhere it is accepted, as long as construction says so
  # rather than pretending: user namespaces can be forbidden where bwrap is
  # installed (Ubuntu 24.04's AppArmor default).
  defp with_bubblewrap({:ok, environment}, fun), do: fun.(environment)

  defp with_bubblewrap({:error, message}, _fun) do
    if @require_sandbox?, do: flunk("LMX_REQUIRE_SANDBOX=1, but " <> message)
    assert message =~ "could not start a sandbox"
  end

  defp sequence?(list, sequence) do
    list
    |> Enum.chunk_every(length(sequence), 1, :discard)
    |> Enum.member?(sequence)
  end
end
