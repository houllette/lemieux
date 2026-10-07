defmodule Lemieux.Extensions.VerifyTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Extensions
  alias Lemieux.Extensions.Verify
  alias Lemieux.Extensions.Verify.Check
  alias Lemieux.Extensions.Verify.Discovery
  alias Lemieux.Harness
  alias Lemieux.Providers.Scripted
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  describe "Discovery" do
    test "a project's own entry point wins over its language's convention", %{tmp_dir: dir} do
      write(dir, "mix.exs", "")
      write(dir, "Makefile", ".PHONY: test\ntest:\n\tmix test --warnings-as-errors\n")

      assert {:ok, %{command: "make test", discovered_from: "Makefile"}} = Discovery.discover(dir)
    end

    test "each ecosystem's ordinary command", %{tmp_dir: dir} do
      cases = [
        {"mix.exs", "", "mix test"},
        {"Cargo.toml", "", "cargo test"},
        {"go.mod", "module x", "go test ./..."},
        {"pytest.ini", "[pytest]", "pytest -q"},
        {"pyproject.toml", "[tool.pytest.ini_options]\n", "pytest -q"},
        {"pom.xml", "<project/>", "mvn -q test"}
      ]

      for {file, contents, command} <- cases do
        project = Path.join(dir, file)
        write(project, file, contents)
        assert {:ok, %{command: ^command}} = Discovery.discover(project), file
      end
    end

    test "package.json runs its test script with the manager its lockfile names", %{
      tmp_dir: dir
    } do
      write(dir, "package.json", JSON.encode!(%{"scripts" => %{"test" => "vitest run"}}))
      assert {:ok, %{command: "npm test"}} = Discovery.discover(dir)

      write(dir, "pnpm-lock.yaml", "")
      assert {:ok, %{command: "pnpm test"}} = Discovery.discover(dir)
    end

    test "npm's placeholder script, a pyproject without pytest and nothing at all are no check",
         %{tmp_dir: dir} do
      write(
        dir,
        "package.json",
        ~s({"scripts": {"test": "echo \\"Error: no test specified\\" && exit 1"}})
      )

      write(dir, "pyproject.toml", "[project]\nname = \"x\"\n")

      assert :none = Discovery.discover(dir)
    end

    test "a configured command is used as given, and check.sh is never proposed", %{tmp_dir: dir} do
      write(dir, "check.sh", "exit 0")
      assert :none = Discovery.discover(dir)

      assert {:ok, %{command: "./check.sh", discovered_from: "command"}} =
               Discovery.discover(dir, command: "./check.sh")
    end
  end

  describe "Check" do
    test "a zero exit passes and a non-zero one fails with its output", %{tmp_dir: dir} do
      assert %{"status" => "passed", "exit_status" => 0} = Check.run("true", dir)

      assert %{"status" => "failed", "exit_status" => 3, "output" => output} =
               Check.run("echo 'assertion failed at line 12'; exit 3", dir)

      assert output =~ "assertion failed at line 12"
    end

    test "a command that outlives its deadline is reported as timed out", %{tmp_dir: dir} do
      assert %{"status" => "timed_out"} = Check.run("sleep 5", dir, timeout_ms: 200)
    end

    test "output keeps its head and its tail", %{tmp_dir: dir} do
      command = "echo FIRST; for i in $(seq 1 2000); do echo filler$i; done; echo LAST; exit 1"
      result = Check.run(command, dir, max_output_bytes: 2_000)

      assert result["output"] =~ "FIRST"
      assert result["output"] =~ "LAST"
      assert result["output"] =~ "bytes omitted"
    end

    test "an excerpt is the end of the output, from a line boundary" do
      output = Enum.map_join(1..100, "\n", &"line #{&1}")
      excerpt = Check.excerpt(output, 30)

      assert excerpt =~ "line 100"
      refute excerpt =~ "line 1\n"
      assert excerpt =~ "bytes omitted"
    end
  end

  describe "init/1" do
    test "rejects options it would silently ignore" do
      assert {:error, message} = Verify.init(comand: "mix test")
      assert message =~ "comand"
      assert {:error, _} = Verify.init(max_continuations: -1)
      assert {:ok, %Verify{command: :auto, max_continuations: 2}} = Verify.init([])
    end

    test "the coding recipe offers it by name, off unless asked for" do
      refute Keyword.has_key?(Extensions.coding("test:model", Scripted.new([])), :verify)

      assert [verify: {Verify, [cwd: "/repo", command: "mix test"]}] =
               Extensions.coding("test:model", Scripted.new([]),
                 verify: [command: "mix test"],
                 delegate: false,
                 cwd: "/repo"
               )
    end
  end

  describe "the stop hook, in a session" do
    setup %{tmp_dir: tmp_dir} do
      runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
      start_supervised!({Lemieux.Supervisor, name: runtime})
      File.mkdir_p!(Path.join(tmp_dir, "work"))
      %{runtime: runtime, cwd: Path.join(tmp_dir, "work"), store: JSONL.new(tmp_dir)}
    end

    defp start(ctx, script, verify_opts) do
      provider = Scripted.new(script)
      {:ok, harness} = Harness.assemble(Harness.new(), [{Verify, verify_opts}])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: ctx.runtime,
          store: ctx.store,
          provider: provider,
          model: "test:verify",
          cwd: ctx.cwd,
          subscriber: self(),
          harness: harness
        )

      {session, provider}
    end

    defp run(session, text) do
      id = Session.id(session)
      :ok = Session.prompt(session, text)
      assert_receive {:lemieux, ^id, {:finished, reason}}, 10_000
      reason
    end

    defp messages(session) do
      %{entries: entries} = Session.snapshot(session)

      for %Entry{type: :user, payload: %{"text" => text}} <- entries,
          String.starts_with?(text, Verify.marker()),
          do: text
    end

    defp edit_then(text), do: [write_call(), Scripted.complete(text)]

    defp write_call,
      do: Scripted.tool_call("w1", "write", %{"path" => "notes.txt", "content" => "hello\n"})

    test "a failing check after an edit sends the model back with the output", ctx do
      {session, provider} =
        start(
          ctx,
          edit_then("Done.") ++ [Scripted.complete("It was already failing; stopping.")],
          command: "echo 'expected 2, got 3'; exit 1",
          max_continuations: 2
        )

      assert run(session, "write the file") == :stop
      assert [feedback] = messages(session)
      assert feedback =~ "failed with exit status 1"
      assert feedback =~ "expected 2, got 3"
      assert feedback =~ "(Check 1 of 2.)"
      assert feedback =~ "stop without making further changes"

      # The model answered without editing, so there was nothing to check again.
      assert length(Scripted.requests(provider)) == 3

      assert {:ok, %{last: %{"status" => "failed", "exit_status" => 1}}} =
               Verify.status(session)
    end

    test "the allowance bounds how many times a failing check sends the model back", ctx do
      {session, provider} =
        start(
          ctx,
          edit_then("Done.") ++ edit_then("Fixed.") ++ edit_then("Fixed again."),
          command: "exit 1",
          max_continuations: 1
        )

      assert run(session, "write the file") == :stop
      assert [_one] = messages(session)
      assert length(Scripted.requests(provider)) == 4
    end

    test "a passing check lets the turn end", ctx do
      {session, provider} = start(ctx, edit_then("Done."), command: "true")

      assert run(session, "write the file") == :stop
      assert messages(session) == []
      assert length(Scripted.requests(provider)) == 2
      assert {:ok, %{last: %{"status" => "passed"}}} = Verify.status(session)
    end

    test "a turn that edited nothing is not checked", ctx do
      {session, _provider} =
        start(ctx, [Scripted.complete("Nothing to change.")], command: "exit 1")

      assert run(session, "explain the code") == :stop
      assert messages(session) == []
      assert {:ok, %{last: nil}} = Verify.status(session)
    end

    test "a check the model already ran and saw pass after its last edit is not repeated",
         ctx do
      {session, _provider} =
        start(
          ctx,
          [
            write_call(),
            Scripted.tool_call("b1", "bash", %{"command" => "cd . && true"}),
            Scripted.complete("Done and tested.")
          ],
          command: "true"
        )

      assert run(session, "write and test") == :stop
      assert {:ok, %{last: nil}} = Verify.status(session)
    end

    test "turned off at runtime, it does nothing", ctx do
      {session, _provider} = start(ctx, edit_then("Done."), command: "exit 1")

      assert {:ok, _document} = Verify.set_enabled(session, false)
      assert {:ok, %{enabled: false}} = Verify.status(session)

      assert run(session, "write the file") == :stop
      assert messages(session) == []
    end

    test "another stop hook's message between the edit and the stop does not hide the edit",
         ctx do
      # A hook ahead of Verify sends the model back once. Its message is a
      # user entry, and Verify used to take every unmarked user entry for the
      # person's prompt — so the edit before it no longer counted, and the
      # check never ran.
      nudge = fn _reason, context ->
        if context.stop_hook_active, do: :allow, else: {:deny, "keep going"}
      end

      provider =
        Scripted.new(
          edit_then("Done.") ++
            [Scripted.complete("Really done."), Scripted.complete("It was already broken.")]
        )

      {:ok, harness} =
        Harness.assemble(Harness.append_hooks(Harness.new(), stop: nudge), [
          {Verify, command: "echo broken; exit 1"}
        ])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: ctx.runtime,
          store: ctx.store,
          provider: provider,
          model: "test:verify",
          cwd: ctx.cwd,
          subscriber: self(),
          harness: harness
        )

      id = Session.id(session)
      :ok = Session.prompt(session, "write the file")
      assert_receive {:lemieux, ^id, {:finished, :stop}}

      assert {:ok, %{last: %{"status" => "failed"}}} = Verify.status(session)
      assert [feedback] = messages(session)
      assert feedback =~ "failed with exit status 1"
    end

    test "a command that cannot run is not the model's to fix", ctx do
      {session, _provider} =
        start(ctx, edit_then("Done."), command: "definitely-not-a-command-lmx-verify")

      assert run(session, "write the file") == :stop
      assert messages(session) == []
    end
  end
end
