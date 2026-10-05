"""Exercise real packaged tools and cross-process resume with a scripted provider.

Run: python3 test/release_session_smoke.py BINARY [REPLACEMENT]
BINARY is a built or installed lmx launcher (bin/lmx, or bin/lmx.cmd on
Windows). With REPLACEMENT, the session started by BINARY is resumed by it,
and the checks of the binary itself run against REPLACEMENT, the candidate.
Those checks: the archive root carries its license notices; `--version` and
`help` write nothing to standard error; a working directory's .env is never
read; a command the agent runs gets the person's environment, not the
release VM's (their PATH, no BINDIR, ROOTDIR or RELEASE_*, and their own
`erl` runs, where PATH has one); and on Unix, Ctrl-C, a closed terminal and SIGTERM (to the launcher or
to the VM itself) cancel the running turn and exit 130, 129 or 143, a
launcher killed outright takes its VM with it, and every one of those runs
the VM's SIGTERM traps. On a pseudo-terminal, the terminal UI leaves its
screen when its launcher is killed (its VM writing why only after that), and
its VM, sent SIGTERM, exits 143. No model is called; the terminal UI is
opened with no configuration and sent no prompt.
"""
import json
import os
from pathlib import Path
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import time

SCRIPT = r'''
defmodule ReleaseSessionSmoke do
  import Kernel, except: [apply: 2]
  alias Lemieux.Providers.Scripted
  def init(config: config) do
    root = config["root"]
    phase = config["phase"]
    {:ok, supervisor} = Lemieux.Supervisor.start_link(name: ReleaseSessionSmoke.Runtime)
    script = if phase == "seed", do: [
      Scripted.tool_call("write", "write", %{"path" => "probe.txt", "content" => "before"}),
      Scripted.tool_call("edit", "edit", %{"path" => "probe.txt", "old" => "before", "new" => "after"}),
      Scripted.tool_call("read", "read", %{"path" => "probe.txt"}),
      Scripted.tool_call("bash", "bash", %{"command" => "echo packaged-shell-ok"}),
      Scripted.complete("seed complete")
    ], else: [Scripted.complete("resume complete")]
    provider = Scripted.new(script)
    try do
      opts = [supervisor: ReleaseSessionSmoke.Runtime, provider: provider,
        store: Lemieux.Store.JSONL.new(Path.join(root, "sessions")),
        model: "test:model", cwd: root, max_requests: 6, compact_at: nil]
      {:ok, session} = if phase == "seed", do: Lemieux.start_session(opts),
        else: Lemieux.resume_session([resume: File.read!(Path.join(root, "id"))] ++ opts)
      File.write!(Path.join(root, "id"), Lemieux.Session.id(session))
      {:ok, result} = Lemieux.Testing.prompt(session, phase, 15_000)
      :stop = result.stop_reason
      "after" = File.read!(Path.join(root, "probe.txt"))
      results = Enum.filter(result.entries, &(&1.type == :tool_result))
      4 = length(results)
      true = Enum.all?(results, &(&1.payload["error"] == false))
      true = Enum.any?(results, &String.contains?(&1.payload["output"], "packaged-shell-ok"))
      true = Enum.any?(results, &String.contains?(&1.payload["output"], "after"))
      if phase == "resume" do
        [request] = Scripted.requests(provider)
        true = Enum.any?(request.entries, &(&1.type == :tool_result))
      end
      {:ok, []}
    after
      Supervisor.stop(supervisor)
      {_, agent} = provider
      Agent.stop(agent)
    end
  end
  def apply(harness, _), do: harness
end
'''

# One bash call, whose output — what the command saw of its environment — is
# written where the smoke reads it.
ENV_SCRIPT = r'''
defmodule ReleaseEnvironmentSmoke do
  import Kernel, except: [apply: 2]
  alias Lemieux.Providers.Scripted
  def init(config: %{"root" => root, "probe" => probe}) do
    {:ok, supervisor} = Lemieux.Supervisor.start_link(name: ReleaseEnvironmentSmoke.Runtime)
    provider = Scripted.new([
      Scripted.tool_call("probe", "bash", %{"command" => probe}),
      Scripted.complete("probed")
    ])
    try do
      {:ok, session} = Lemieux.start_session(supervisor: ReleaseEnvironmentSmoke.Runtime,
        provider: provider, store: Lemieux.Store.JSONL.new(Path.join(root, "sessions")),
        model: "test:model", cwd: root, max_requests: 3, compact_at: nil)
      {:ok, result} = Lemieux.Testing.prompt(session, "probe", 30_000)
      [output] = for %{type: :tool_result, payload: payload} <- result.entries, do: payload["output"]
      File.write!(Path.join(root, "child-environment.txt"), output)
      {:ok, []}
    after
      Supervisor.stop(supervisor)
      {_, agent} = provider
      Agent.stop(agent)
    end
  end
  def apply(harness, _), do: harness
end
'''

# What the probe prints: the PATH it got, every variable the release, erlexec
# or the launcher sets that it inherited, and whether `erl` runs.
ENV_PROBE = r'''printf 'PATH=%s\n' "$PATH"
env | grep -E '^(BINDIR|ROOTDIR|EMU|PROGNAME|ERL_CRASH_DUMP|RELEASE_[A-Za-z0-9_]*|LMX_[A-Za-z0-9_]*)=' | sed 's/^/inherited /'
if command -v erl >/dev/null 2>&1; then
  printf 'erl=%s\n' "$(command -v erl)"
  erl -noshell -eval 'halt().' > erl.out 2>&1 && echo erl-ran || { echo erl-failed; cat erl.out; }
else
  echo erl-missing
fi'''

# Starts a turn the scripted provider answers only after two minutes, under
# the runtime name lmx itself mounts, records the VM's pid, and then holds
# the command, so that only a signal can end it. Its SIGTERM trap, newer than
# lmx's own, stands in for the terminal UI's, which leaves the screen.
BUSY_SCRIPT = r'''
defmodule ReleaseSignalSmoke do
  import Kernel, except: [apply: 2]
  alias Lemieux.Providers.Scripted
  def init(config: %{"root" => root}) do
    case Lemieux.Supervisor.start_link(name: Lemieux.Supervisor) do
      {:ok, pid} -> Process.unlink(pid)
      {:error, {:already_started, _pid}} -> :ok
    end
    {:ok, session} = Lemieux.start_session(supervisor: Lemieux.Supervisor,
      provider: Scripted.new([Scripted.delayed(120_000, Scripted.complete("too late"))]),
      store: Lemieux.Store.JSONL.new(Path.join(root, "sessions")),
      model: "test:model", cwd: root, tools: [])
    :ok = Lemieux.Session.prompt(session, "take your time")
    {:ok, _id} = System.trap_signal(:sigterm, fn ->
      File.write!(Path.join(root, "trapped"), "sigterm")
      :ok
    end)
    File.write!(Path.join(root, "vm.pid"), System.pid())
    Process.sleep(:infinity)
  end
  def apply(harness, _), do: harness
end
'''


def lmx(binary, args, env, cwd, **options):
    return subprocess.run([str(binary), *args], env=env, cwd=cwd, capture_output=True, text=True,
                          timeout=120, **options)


def release_root(binary):
    """The release BINARY runs: the one it sits in (an unpacked archive's
    bin/lmx), or the installation named by the shim install.py writes."""
    root = binary.parent.parent
    if (root / "releases").is_dir():
        return root
    try:
        text = binary.read_text()
    except (OSError, UnicodeDecodeError):
        return None
    match = re.search(r"^export LMX_INSTALL_HOME=(.+)$", text, re.MULTILINE)
    if match:
        current = Path(shlex.split(match.group(1))[0]) / "current"
        if (current / "releases").is_dir():
            return current.resolve()
    return None


def check_archive_root(binary):
    """An unpacked archive carries its license notices at the root and no shared cookie."""
    root = release_root(binary)
    if root is None:
        print(f"skipped the archive root checks: no release found behind {binary}", file=sys.stderr)
        return
    for name in ("LICENSE", "NOTICE", "THIRD_PARTY_NOTICES"):
        assert (root / name).is_file(), f"the release root lacks {name}"
    assert "Rust crates" in (root / "THIRD_PARTY_NOTICES").read_text()
    assert not (root / "releases" / "COOKIE").exists(), "the archive ships a shared cookie"


def check_quiet(binary, env, cwd):
    """Heart used to print four lines around every command."""
    for args in (["--version"], ["help", "models"]):
        result = lmx(binary, args, env, cwd)
        if result.returncode:
            raise RuntimeError(f"lmx {' '.join(args)} failed: {result.stderr}")
        if os.name != "nt":
            assert result.stderr == "", f"lmx {' '.join(args)} wrote to stderr: {result.stderr!r}"


def check_dotenv_ignored(binary, scratch):
    """A cloned repository's .env must neither run commands nor configure lmx."""
    launch = scratch / "dotenv-repository"
    launch.mkdir()
    marker = scratch / "dotenv-command-ran"
    config = scratch / "dotenv-config.json"
    config.write_text('{"version": 1}\n')
    config.chmod(0o600)
    # LMX_CONFIG must be unset here: a .env never overrides the environment,
    # so the check is only meaningful for variables the person did not set.
    env = {name: value for name, value in os.environ.items() if not name.startswith("LMX_")}
    if os.name != "nt":
        home = scratch / "dotenv-home"
        home.mkdir()
        env["HOME"] = str(home)
    command = ["explain", "--no-delegate"]
    if os.name == "nt":
        # Erlang reports every writable file on Windows as mode 0666, and
        # lmx refuses a config file others may write, its own default one
        # included, so this leg names none. The .env's command and its other
        # variables are still checked.
        command += ["--config", "none"]
    before = lmx(binary, command, env, launch)
    (launch / ".env").write_text(
        f"MARK=$(touch {marker})\n"
        "LMX_PROJECT_MCP=1\n"
        "LMX_BASE_URL=http://127.0.0.1:9/v1\n"
        f"LMX_CONFIG={config}\n")
    after = lmx(binary, command, env, launch)
    assert not marker.exists(), "lmx ran a command from the working directory's .env"
    assert before.returncode == 0 and after.returncode == 0, after.stderr
    assert json.loads(after.stdout) == json.loads(before.stdout), "a .env changed what lmx explains"


def check_child_environment(binary, env, scratch, versions):
    """A command the agent runs gets the environment lmx was started with. The
    release VM's own put its ERTS first on PATH, where the person's `erl` (and
    their `elixir` and `mix`) failed with "cannot get bootfile", and carried
    BINDIR, ROOTDIR, RELEASE_* and the launcher's variables into every command."""
    if os.name == "nt":
        return
    root = scratch / "child-environment"
    extension = root / "extension"
    extension.mkdir(parents=True)
    (extension / "environment.exs").write_text(ENV_SCRIPT)
    (extension / "extension.json").write_text(json.dumps({
        "schema_version": 1, "name": "environment-smoke", "module": "ReleaseEnvironmentSmoke",
        "script": "environment.exs", "versions": versions,
        "options": {"root": str(root), "probe": ENV_PROBE}}))
    result = lmx(binary, ["explain", "--config", "none", "--no-delegate", "--no-project-mcp",
                          "--extension-dir", str(extension)], env, root)
    if result.returncode:
        raise RuntimeError("the environment probe failed: " + result.stderr)
    seen = (root / "child-environment.txt").read_text()
    lines = seen.splitlines()
    assert f"PATH={env['PATH']}" in lines, "a command did not get the person's PATH:\n" + seen
    installed = release_root(binary)
    if installed is not None:
        assert str(installed) not in next(line for line in lines if line.startswith("PATH=")), seen
    inherited = {line[len("inherited "):].split("=", 1)[0]: line.split("=", 1)[1]
                 for line in lines if line.startswith("inherited ")}
    person = {name for name in env if re.match(r"^(BINDIR|ROOTDIR|EMU|PROGNAME|ERL_CRASH_DUMP|RELEASE_|LMX_)", name)}
    leaked = sorted(set(inherited) - person)
    assert not leaked, f"a command inherited what lmx set for its VM: {leaked}"
    for name in person:
        assert inherited.get(name) == env[name], f"a command lost the person's {name}: " + seen
    erl = shutil.which("erl", path=env["PATH"])
    if erl is None:
        print("skipped running erl from a command: the person's PATH has none", file=sys.stderr)
        assert "erl-missing" in lines, seen
    else:
        assert f"erl={erl}" in lines, f"a command found another erl than the person's {erl}:\n" + seen
        assert "erl-ran" in lines, "the person's erl did not run from a command:\n" + seen


def alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    return True


def wait_for(check, seconds, what):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(0.1)
    raise RuntimeError(f"timed out waiting for {what}")


def busy_lmx(binary, env, root, versions):
    """Starts lmx holding a running turn; returns the launcher and the VM's pid."""
    extension = root / "extension"
    extension.mkdir(parents=True)
    (extension / "busy.exs").write_text(BUSY_SCRIPT)
    (extension / "extension.json").write_text(json.dumps({
        "schema_version": 1, "name": "signal-smoke", "module": "ReleaseSignalSmoke",
        "script": "busy.exs", "versions": versions, "options": {"root": str(root)}}))
    # A process group of its own, as a shell gives a job, so that a signal can
    # reach the whole group the way a terminal sends Ctrl-C or a hangup.
    launcher = subprocess.Popen([str(binary), "explain", "--config", "none", "--no-delegate",
                                 "--no-project-mcp", "--extension-dir", str(extension)],
                                env=env, cwd=root, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                start_new_session=True)
    pid_file = root / "vm.pid"
    try:
        vm = wait_for(lambda: pid_file.exists() and pid_file.read_text().strip(), 90, "the busy turn")
    except RuntimeError:
        launcher.kill()
        raise RuntimeError("the busy extension never started: " + launcher.communicate()[1])
    return launcher, int(vm)


def cancelled(root):
    transcripts = (root / "sessions").glob("*.jsonl")
    return any('"type":"cancelled"' in path.read_text() for path in transcripts)


# How each way of stopping lmx arrives, and the status the launcher reports.
SIGNALS = (
    # A terminal sends Ctrl-C and a hangup to its whole foreground group, so
    # the VM receives them too; it must leave both to the launcher.
    ("ctrl-c", lambda launcher, vm: os.killpg(launcher.pid, signal.SIGINT), 130),
    ("closed terminal", lambda launcher, vm: os.killpg(launcher.pid, signal.SIGHUP), 129),
    ("kill", lambda launcher, vm: os.kill(launcher.pid, signal.SIGTERM), 143),
    # The VM's own SIGTERM handling, without the launcher's forwarding: the
    # VM used to exit 0 at once, before the cancellation was recorded.
    ("kill of the VM", lambda launcher, vm: os.kill(vm, signal.SIGTERM), 143),
)


def check_signals(binary, env, scratch, versions):
    """Ctrl-C, a closed terminal, SIGTERM and a killed launcher all cancel the turn, run the
    VM's SIGTERM traps and end the VM."""
    if os.name == "nt":
        return
    for name, send, status in SIGNALS:
        root = scratch / ("signal-" + name.replace(" ", "-"))
        launcher, vm = busy_lmx(binary, env, root, versions)
        send(launcher, vm)
        _, stderr = launcher.communicate(timeout=60)
        assert launcher.returncode == status, (name, launcher.returncode, stderr)
        wait_for(lambda: not alive(vm), 10, f"the VM to exit after {name}")
        assert cancelled(root), f"{name} did not record the cancellation"
        assert (root / "trapped").exists(), f"{name} did not run the VM's SIGTERM traps"
    # Nothing can forward a signal for a launcher killed outright; its VM
    # used to stop itself without running the other traps.
    root = scratch / "signal-launcher-killed"
    launcher, vm = busy_lmx(binary, env, root, versions)
    launcher.kill()
    launcher.communicate(timeout=60)
    wait_for(lambda: not alive(vm), 30, "the VM to notice its launcher was killed")
    assert cancelled(root), "a killed launcher's VM did not record the cancellation"
    assert (root / "trapped").exists(), "a killed launcher's VM did not run its SIGTERM traps"


def processes():
    """Each running process's parent, by pid (`ps`, as on macOS and Linux alike)."""
    table = subprocess.check_output(["ps", "-A", "-o", "pid=,ppid="], text=True)
    return {int(pid): int(ppid) for pid, ppid in (line.split() for line in table.splitlines() if line.strip())}


def child_of(parent, seconds, what):
    def find():
        children = [pid for pid, ppid in processes().items() if ppid == parent]
        return children[0] if children else None
    return wait_for(find, seconds, what)


# How the terminal UI's VM is stopped; the status the launcher then reports:
# its own for a killed launcher (nobody is left to report the VM's), the VM's
# for a SIGTERM sent to the VM itself; and what the VM must say once the
# screen is gone. Written while the screen was up, the line went with it.
TERMINAL_STOPS = (
    ("killed launcher", lambda launcher, vm: os.kill(launcher, signal.SIGKILL), None,
     b"lmx: the launcher is gone"),
    ("SIGTERM to the VM", lambda launcher, vm: os.kill(vm, signal.SIGTERM), 143, None),
)


def check_terminal_restored(binary, env, scratch):
    """The terminal UI leaves the alternate screen however its VM is stopped.

    The launcher runs under a shell that stays the session leader, as a person's
    shell does; killing the session leader itself would revoke the terminal.
    For a killed launcher nothing but the VM can restore the screen: the
    launcher's own restore dies with it. That VM used to stop with the screen
    up, and the shell came back inside the alternate screen with the cursor
    hidden. The line saying why was written inside that screen, and went with
    it. A SIGTERM sent to the VM itself ended it with 1, not 143."""
    if os.name == "nt":
        return
    for name, stop, status, said in TERMINAL_STOPS:
        output, opened, exited = run_terminal_ui(binary, env, scratch / ("tui-" + name.replace(" ", "-")), stop)
        left = output.find(b"\x1b[?1049l", opened)
        assert left >= 0, \
            f"{name}: the terminal UI did not leave its screen: " + repr(bytes(output[opened:][-600:]))
        if said is not None:
            assert said in output[left:], \
                f"{name}: {said!r} was not written after the screen was left: " + repr(bytes(output[opened:][-600:]))
        if status is not None:
            assert exited == status, f"{name}: lmx exited {exited}, not {status}"


def run_terminal_ui(binary, env, root, stop):
    """Opens the terminal UI on a pseudo-terminal, stops it with STOP once it is
    up, and returns what the terminal received, where the stop began, and the
    launcher's exit status as its shell saw it (None if it never said)."""
    import fcntl
    import pty
    import struct
    import termios
    home = root / "home"
    home.mkdir(parents=True)
    work = root / "work"
    work.mkdir()
    tui_env = dict(env, HOME=str(home), TERM="xterm-256color", LMX_CHECK_UPDATES="0")
    tui_env.pop("LMX_HOME", None)
    shell, fd = pty.fork()
    if shell == 0:
        os.chdir(work)
        os.execve("/bin/sh", ["sh", "-c", '"$0"; echo "[lmx exited $?]"; exec sleep 60', str(binary)], tui_env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    output = bytearray()

    def read(seconds, until=None):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if until is not None and until(output):
                return True
            if select.select([fd], [], [], 0.1)[0]:
                try:
                    data = os.read(fd, 65536)
                except OSError:
                    return False
                if not data:
                    return False
                output.extend(data)
        return until is not None and until(output)

    try:
        if not read(90, lambda seen: b"\x1b[?1049h" in seen):
            raise RuntimeError("the terminal UI never opened: " + bytes(output[-2000:]).decode(errors="replace"))
        launcher = child_of(shell, 10, "the launcher")
        vm = child_of(launcher, 10, "the VM")
        # The screen registers its SIGTERM trap once it is up.
        read(3)
        opened = len(output)
        stop(launcher, vm)
        read(30, lambda _seen: not alive(vm))
        assert not alive(vm), "the terminal UI's VM did not stop"
        # What the VM wrote as it stopped may still be waiting to be read.
        read(1)
        read(10, lambda seen: b"[lmx exited " in seen[opened:])
        exited = re.search(rb"\[lmx exited (\d+)\]", bytes(output[opened:]))
        return output, opened, int(exited.group(1)) if exited else None
    finally:
        try:
            os.kill(shell, signal.SIGKILL)
        except ProcessLookupError:
            pass
        os.waitpid(shell, 0)
        os.close(fd)


def main():
    binary = Path(sys.argv[1]).resolve()
    replacement = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else binary
    with tempfile.TemporaryDirectory(prefix="lmx-session-smoke-") as scratch:
        scratch = Path(scratch)
        extension = scratch / "extension"
        extension.mkdir()
        (extension / "smoke.exs").write_text(SCRIPT)
        manifest = {"schema_version": 1, "name": "session-smoke", "module": "ReleaseSessionSmoke",
                    "script": "smoke.exs"}
        # A VM that dies writes erl_crash.dump; keep any in the scratch directory.
        env = dict(os.environ, LMX_CONFIG="none", ERL_CRASH_DUMP=str(scratch / "erl_crash.dump"))
        check_archive_root(replacement)
        check_quiet(replacement, env, scratch)
        check_dotenv_ignored(replacement, scratch)
        for phase in ("seed", "resume"):
            active_binary = binary if phase == "seed" else replacement
            diagnostics = subprocess.check_output([str(active_binary), "explain", "--config", "none",
                "--no-delegate", "--no-project-mcp", "--no-user-extensions"], env=env, cwd=scratch, text=True)
            manifest["versions"] = json.loads(diagnostics)["diagnostics"]["versions"]
            manifest["options"] = {"root": str(scratch), "phase": phase}
            (extension / "extension.json").write_text(json.dumps(manifest))
            result = subprocess.run([str(active_binary), "explain", "--config", "none", "--no-delegate",
                                     "--no-project-mcp", "--extension-dir", str(extension)],
                                    env=env, cwd=scratch, capture_output=True, text=True, timeout=120)
            if result.returncode:
                raise RuntimeError(f"{phase}: {result.stderr}")
            report = json.loads(result.stdout)
            assert report["extensions"][-1]["module"] == "ReleaseSessionSmoke"
        check_child_environment(replacement, env, scratch, manifest["versions"])
        check_signals(replacement, env, scratch, manifest["versions"])
        check_terminal_restored(replacement, env, scratch)
        print("verified notices, quiet output, ignored .env, packaged read/write/edit/bash, "
              "cross-process resume, the environment commands inherit, signal handling and "
              "the terminal UI's exit")


if __name__ == "__main__":
    main()
