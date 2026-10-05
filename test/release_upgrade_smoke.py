"""Build two real releases and exercise the production updater without a provider.

Unix only. Uses a temporary source copy and the already fetched dependencies.
LMX_MIX may select the pinned local Mix command, e.g. 'mise exec -- mix'.
No release is published; all update bytes come from the local version B archive.
"""
import argparse
import hashlib
from contextlib import contextmanager
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
MIX = shlex.split(os.environ.get("LMX_MIX", "mix"))
# Lmx.Update.stage/2 installs only an offer whose manifest verifies against
# the release key; a throwaway key stands in for the offline one. A
# predecessor built before update signing takes the bare manifest entry.
SIGNED_OFFER = '''
  {offer, sign_opts} =
    if Code.ensure_loaded?(Lmx.Update.Signature) do
      {public, private} = :crypto.generate_key(:eddsa, :ed25519)
      body = JSON.encode!(%{"schema_version" => 1, "version" => v["info"]["version"],
        "targets" => %{v["info"]["target"] => v["info"]}})
      {Map.put(v["info"], "signed_manifest",
         %{"manifest" => body, "signature" => Lmx.Update.Signature.sign(body, private)}),
       [public_key: Base.encode64(public)]}
    else
      {v["info"], []}
    end
'''


@contextmanager
def workspace():
    directory = Path(tempfile.mkdtemp(prefix="lmx-update-smoke-"))
    try:
        yield directory
    except BaseException:
        print(f"failed smoke artifacts retained at {directory}", flush=True)
        raise
    else:
        shutil.rmtree(directory)


def patched(path, old, new):
    """Makes one fixture edit in PATH. An anchor that is gone fails the smoke:
    a plain replace that matched nothing left the fixture silently unchanged."""
    text = path.read_text()
    if old not in text:
        raise RuntimeError(f"{path} no longer contains {old!r}; update the upgrade smoke's fixture")
    path.write_text(text.replace(old, new, 1))


# A release build on GitHub's x86-64 macOS runner took more than five
# minutes (the first release run, 2026-10-05); on arm64 it takes about two.
COMMAND_TIMEOUT_S = 900


def run(command, cwd, env, log=None):
    result = subprocess.run(command, cwd=cwd, env=env, capture_output=True, text=True,
                            timeout=COMMAND_TIMEOUT_S)
    if log:
        log.write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"{command[0]} failed: {result.stdout[-2000:]} {result.stderr[-2000:]}")
    return result.stdout.strip()


def rpc(root, expression, env):
    return run([str(root / "bin/lmx-release"), "rpc", expression], ROOT, env)


def artifact_info(archive):
    with tarfile.open(archive) as bundle:
        entries = [p for p in bundle.getmembers() if p.name.startswith("releases/") and p.name.endswith("/release.json")]
        if len(entries) != 1 or entries[0].size > 100_000:
            raise RuntimeError("expected one release identity")
        return json.load(bundle.extractfile(entries[0]))


def exercise(old, archive, info, prefix, fallback=False, expect_hot=True, failure=None, following=None, hold_old_code=False,
             marker=None, following_marker=None):
    home = prefix / "share/lmx"
    sums = archive.parent / "SHA256SUMS"
    sums.write_text(f"{hashlib.sha256(old.read_bytes()).hexdigest()}  {old.name}\n")
    run([sys.executable, str(ROOT / "scripts/install.py"), str(old), "--checksums", str(sums),
         "--prefix", str(prefix)], ROOT, os.environ)
    root = (home / "current").resolve()
    env = dict(os.environ, LMX_CONFIG="none", LMX_INSTALL_HOME=str(home), LMX_RELEASE_ROOT=str(root),
               RELEASE_DISTRIBUTION="sname", RELEASE_NODE=f"lmx_upgrade_{os.getpid()}_{prefix.name.replace('-', '_')}")
    server = subprocess.Popen([str(root / "bin/lmx-release"), "start"], cwd=ROOT, env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        for _ in range(100):
            try:
                if rpc(root, 'IO.puts("ready")', env) == "ready":
                    break
            except RuntimeError:
                time.sleep(0.1)
        else:
            raise RuntimeError("release did not boot")
        values = {"home": str(home), "root": str(root), "archive": str(archive), "info": info,
                  "fallback": fallback, "failure": failure, "hold_old_code": hold_old_code,
                  "sessions": str(prefix / "sessions")}
        payload = json.dumps(json.dumps(values))
        expression = f'''
          v = JSON.decode!({payload})
          {SIGNED_OFFER}
          if v["hold_old_code"] do
            holder = spawn(fn -> Lemieux.upgrade_fixture_wait() end)
            :persistent_term.put(:held_old_code_process, holder)
          end
          if v["failure"] == "callback", do: :persistent_term.put(:held_callback, Lemieux.upgrade_fixture_callback())
          owner = self()
          {{:ok, runtime}} = Lemieux.Supervisor.start_link(name: UpgradeSmoke.Runtime)
          Process.unlink(runtime)
          provider = Lemieux.Providers.Scripted.new([
            Lemieux.Providers.Scripted.complete("before upgrade"),
            Lemieux.Providers.Scripted.complete("after upgrade"),
            Lemieux.Providers.Scripted.complete("after downgrade")])
          Process.unlink(elem(provider, 1))
          {{:ok, session}} = Lemieux.start_session(supervisor: UpgradeSmoke.Runtime,
            provider: provider, store: Lemieux.Store.JSONL.new(v["sessions"]),
            model: "test:model", max_requests: 6, compact_at: nil)
          {{:ok, %{{stop_reason: :stop}}}} = Lemieux.Testing.prompt(session, "before upgrade", 15_000)
          :persistent_term.put(:upgrade_session, session)
          :persistent_term.put(:upgrade_session_id, Lemieux.Session.id(session))
          get = fn _url, opts ->
            {{:cont, {{_, response}}}} = opts[:into].({{:data, File.read!(v["archive"])}}, {{%Req.Request{{}}, %Req.Response{{status: 200}}}})
            {{:ok, response}}
          end
          host = Lmx.Update.host(%{{extensions: []}})
            |> Map.put(:auto?, true)
            |> Map.put(:check?, true)
            |> Map.put(:check, fn ->
              send(owner, {{:check_ready, self()}})
              receive do :continue -> {{:ok, offer}} end
            end)
            |> Map.put(:stage, fn info -> Lmx.Update.stage(info, [home: v["home"], get: get] ++ sign_opts) end)
            |> Map.put(:apply, fn staged, tui ->
              :persistent_term.put(:upgrade_staged, staged)
              if v["failure"] == "prepare", do: File.mkdir_p!(Path.join([v["root"], "lib", "lemieux-" <> v["info"]["version"]]))
              opts = [home: v["home"], root: v["root"], extensions?: v["fallback"]]
              opts = if v["failure"] == "health", do: Keyword.put(opts, :health, fn _, _ -> false end), else: opts
              Lmx.Update.activate(staged, tui, opts)
            end)
          {{:ok, pid}} = Lemieux.TUI.start_link(test_mode: {{80, 24}}, name: nil,
            start: fn -> {{:ok, session}} end,
            id: "upgrade-smoke", model: "test:model", updates: host, title: fn _ -> :ok end)
          Process.unlink(pid)
          Process.register(pid, :upgrade_smoke_tui)
          :persistent_term.put(:upgrade_pid, pid)
          :persistent_term.put(:upgrade_input, :sys.get_state(pid).user_state.input)
          draft = "unsent upgrade draft\\nsecond line"
          :ok = Lemieux.TUI.Editor.replace(:sys.get_state(pid).user_state.input, draft)
          :persistent_term.put(:upgrade_draft, draft)
          receive do {{:check_ready, task}} -> send(task, :continue) after 5_000 -> raise "check did not start" end
          IO.puts("mounted")
        '''
        assert rpc(root, expression, env) == "mounted"
        hot = expect_hot and not fallback and failure is None
        rolled_back = failure == "health"
        expected = ":idle" if hot else ":restart"
        if rolled_back:
            expected = ":idle"
        for _ in range(150):
            report = rpc(root, '''
              pid = Process.whereis(:upgrade_smoke_tui)
              state = :sys.get_state(pid).user_state
              IO.inspect({Lemieux.version(), state.status.update.phase,
                pid == :persistent_term.get(:upgrade_pid), state.input == :persistent_term.get(:upgrade_input),
                ExRatatui.textarea_get_value(state.input) == :persistent_term.get(:upgrade_draft),
                Enum.map(Lemieux.TUI.Notices.items(state), & &1.text)})
            ''', env)
            notice = "rolled back" if rolled_back else ("Update applied" if hot else "restart lmx")
            if expected in report and notice in report:
                break
            time.sleep(0.1)
        else:
            raise RuntimeError(f"update did not complete: {report}")
        assert "true, true, true" in report, report
        if hot and marker:
            # The update's health check sends the screen a version notice once
            # the new code is loaded; the candidate's own text proves the live
            # screen process handled it with that code.
            assert marker in report, report
        old_version = artifact_info(old)["version"]
        assert json.dumps(info["version"] if hot else old_version) in report, report
        print(("live hot upgrade" if hot else "restart fallback") + ": " + report, flush=True)
        if rolled_back:
            result = rpc(root, f'''
              staged = :persistent_term.get(:upgrade_staged)
              {{:error, :quarantined_update}} = Lmx.Update.activate(staged, Process.whereis(:upgrade_smoke_tui), home: {json.dumps(str(home))}, root: {json.dumps(str(root))})
              {{:ok, %{{stop_reason: :stop}}}} = Lemieux.Testing.prompt(:persistent_term.get(:upgrade_session), "after rollback", 15_000)
              IO.puts("failed build quarantined; session still runs")
            ''', env)
            print(result, flush=True)
        if hot:
            session_result = rpc(root, '''
              session = :persistent_term.get(:upgrade_session)
              {:ok, %{stop_reason: :stop}} = Lemieux.Testing.prompt(session, "after upgrade", 15_000)
              IO.inspect({Process.alive?(session),
                Lemieux.Session.snapshot(session).id == :persistent_term.get(:upgrade_session_id)})
            ''', env)
            assert "true, true" in session_result, session_result
            print("same session completed a turn after upgrade", flush=True)
            if following is not None:
                next_info = artifact_info(following)
                next_info["sha256"] = hashlib.sha256(following.read_bytes()).hexdigest()
                values = json.dumps(json.dumps({"info": next_info, "archive": str(following), "home": str(home), "root": str(root)}))
                rpc(root, f'''
                  v = JSON.decode!({values})
                  {SIGNED_OFFER}
                  host = Lmx.Update.host(%{{extensions: []}})
                    |> Map.put(:auto?, true)
                    |> Map.put(:check, fn -> {{:ok, offer}} end)
                    |> Map.put(:stage, fn info ->
                      get = fn _, opts ->
                        {{:cont, {{_, response}}}} = opts[:into].({{:data, File.read!(v["archive"])}}, {{%Req.Request{{}}, %Req.Response{{status: 200}}}})
                        {{:ok, response}}
                      end
                      Lmx.Update.stage(info, [home: v["home"], get: get] ++ sign_opts)
                    end)
                  pid = Process.whereis(:upgrade_smoke_tui)
                  :sys.replace_state(pid, fn state -> put_in(state.user_state.status.update.host, host) end)
                  send(pid, :check_update)
                ''', env)
                for _ in range(150):
                    consecutive = rpc(root, '''
                      pid = Process.whereis(:upgrade_smoke_tui)
                      state = :sys.get_state(pid).user_state
                      IO.inspect({Lemieux.version(), state.status.update.phase, state.status.update.installed,
                        pid == :persistent_term.get(:upgrade_pid),
                        state.input == :persistent_term.get(:upgrade_input),
                        ExRatatui.textarea_get_value(state.input) == :persistent_term.get(:upgrade_draft),
                        Enum.map(Lemieux.TUI.Notices.items(state), & &1.text)})
                    ''', env)
                    if json.dumps(next_info["version"]) in consecutive and (", :idle," in consecutive or ", :restart," in consecutive):
                        break
                    time.sleep(0.1)
                else:
                    raise RuntimeError(f"consecutive update did not finish: {consecutive}")
                assert "true, true, true" in consecutive, consecutive
                if hold_old_code:
                    assert ":restart" in consecutive and json.dumps(info["version"]) in consecutive, consecutive
                    held = rpc(root, '''
                      holder = :persistent_term.get(:held_old_code_process)
                      true = Process.alive?(holder)
                      send(holder, {:finish, self()})
                      receive do {:old_callback, version} -> IO.puts(version) after 5_000 -> raise "old callback lost" end
                    ''', env)
                    assert held == old_version, held
                else:
                    assert ":idle" in consecutive and json.dumps(next_info["version"]) in consecutive, consecutive
                    if following_marker:
                        # As for the first update: the third build's own text
                        # proves the screen handled its notice with that code.
                        assert following_marker in consecutive, consecutive
                session_result = rpc(root, '''
                  {:ok, %{stop_reason: :stop}} = Lemieux.Testing.prompt(:persistent_term.get(:upgrade_session), "after consecutive upgrade", 15_000)
                  IO.puts("same session still runs")
                ''', env)
                print("consecutive update: " + consecutive + " " + session_result, flush=True)
            else:
                downgrade = rpc(root, f'''
              {{:ok, _, _}} = :release_handler.install_release(to_charlist({json.dumps(old_version)}))
              session = :persistent_term.get(:upgrade_session)
              {{:ok, %{{stop_reason: :stop}}}} = Lemieux.Testing.prompt(session, "after downgrade", 15_000)
              true = Process.alive?(session)
              true = Lemieux.Session.id(session) == :persistent_term.get(:upgrade_session_id)
              pid = Process.whereis(:upgrade_smoke_tui)
              send(pid, {{:version_notice, "Downgrade qualification"}})
              IO.inspect({{Lemieux.version(), pid == :persistent_term.get(:upgrade_pid),
                :sys.get_state(pid).user_state.input == :persistent_term.get(:upgrade_input),
                ExRatatui.textarea_get_value(:sys.get_state(pid).user_state.input) == :persistent_term.get(:upgrade_draft)}})
            ''', env)
                assert json.dumps(old_version) in downgrade and "true, true, true" in downgrade, downgrade
                print("live downgrade: " + downgrade, flush=True)
    finally:
        try:
            rpc(root, "System.stop()", env)
        except RuntimeError:
            server.terminate()
        server.communicate(timeout=20)
    launcher = prefix / "bin/lmx"
    selected_version = artifact_info(following)["version"] if following else (old_version if rolled_back else info["version"])
    assert run([str(launcher), "--version"], ROOT, dict(os.environ, LMX_CONFIG="none")) == "lmx " + selected_version
    assert list((home / "running").glob("*")) == [], "launcher leaked its lease"
    print("cold boot selected v" + selected_version, flush=True)


def qualify_archives(old, new, scratch, expect_hot=False, marker=None):
    old_info = artifact_info(old)
    info = artifact_info(new)
    assert old_info["target"] == info["target"], "archive targets differ"
    eligible = {"version": old_info["version"], "build_id": old_info["build_id"]} in info["upgrade_from"]
    if expect_hot:
        assert eligible, "candidate does not declare this exact predecessor"
    else:
        assert not eligible, "restart decision unexpectedly declares a hot path"
    info["sha256"] = hashlib.sha256(new.read_bytes()).hexdigest()
    a_root, b_root = scratch / "a", scratch / "b"
    for archive, destination in ((old, a_root), (new, b_root)):
        destination.mkdir()
        with tarfile.open(archive) as bundle:
            bundle.extractall(destination, filter="data")
    if os.name != "nt":
        exercise(old, new, info, scratch / "actual-install", expect_hot=expect_hot, marker=marker)
        if expect_hot:
            exercise(old, new, info, scratch / "forced-restart", fallback=True)
            exercise(old, new, info, scratch / "interrupted-preparation", failure="prepare")
            exercise(old, new, info, scratch / "failed-health", failure="health")
    else:
        assert not expect_hot, "Windows only supports restart qualification"
    launcher = "lmx.cmd" if os.name == "nt" else "lmx"
    run([sys.executable, str(ROOT / "test/release_session_smoke.py"), str(a_root / "bin" / launcher),
         str(b_root / "bin" / launcher)], ROOT, dict(os.environ, LMX_CONFIG="none"))
    print("verified actual previous/candidate archives and transcript resume", flush=True)
    return {"schema_version": 1, "target": info["target"], "from": old_info, "to": info,
            "previous_sha256": hashlib.sha256(old.read_bytes()).hexdigest(),
            "candidate_sha256": info["sha256"], "live_hot_upgrade": expect_hot,
            "live_downgrade": expect_hot, "restart_install": os.name != "nt",
            "live_session_survived": expect_hot, "unsent_draft_preserved": os.name != "nt",
            "cold_boot": True, "tools_and_transcript_resume": True,
            "interrupted_preparation_fallback": expect_hot, "failed_health_rolled_back": expect_hot,
            "failed_build_quarantined": expect_hot,
            "windows_manual_restart": os.name == "nt"}


def synthetic():
    if os.name == "nt":
        raise SystemExit("hot upgrade smoke requires Unix")
    with workspace() as scratch:
        scratch = Path(scratch)
        checkout = scratch / "checkout"
        files = subprocess.check_output(["git", "ls-files", "-co", "--exclude-standard", "-z"], cwd=ROOT).decode().split("\0")
        for name in files:
            if not name or name == ".mcp.json" or not (ROOT / name).is_file():
                continue
            destination = checkout / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, destination)
        (checkout / "deps").symlink_to(ROOT / "deps", target_is_directory=True)
        dist = checkout / "dist/lmx"
        (dist / "deps").symlink_to(ROOT / "dist/lmx/deps", target_is_directory=True)
        env = dict(os.environ, MIX_ENV="prod", LMX_CONFIG="none")
        env.pop("LMX_UPGRADE_FROM", None)
        env.pop("TARGET_ABI", None)
        (checkout / "VERSION").write_text("0.1.0\n")
        mix = checkout / "mix.exs"
        import re
        mix.write_text(re.sub(r'@version "[^"]+"', '@version "0.1.0"', mix.read_text(), count=1))
        library = checkout / "lib/lemieux.ex"
        library.write_text(library.read_text().replace('\nend', '\n  def upgrade_fixture_callback, do: fn -> @version end\n  def upgrade_fixture_wait do\n    receive do {:finish, caller} -> send(caller, {:old_callback, @version}) end\n  end\nend'))
        print("building version A", flush=True)
        run(MIX + ["release", "--overwrite"], dist, env, scratch / "build-a.log")
        a_root = scratch / "a"
        a_root.mkdir()
        a_tar = scratch / "a.tar.gz"
        shutil.copy2(dist / "_build/prod/lmx-0.1.0.tar.gz", a_tar)
        with tarfile.open(a_tar) as archive:
            archive.extractall(a_root, filter="data")
        (checkout / "VERSION").write_text("0.1.1\n")
        patched(mix, '@version "0.1.0"', '@version "0.1.1"')
        tui = checkout / "lib/lemieux/tui.ex"
        patched(tui, 'Notices.say(state, :info, notice)', 'Notices.say(state, :info, "[upgrade-smoke] " <> notice)')
        print("building version B and reviewed test path", flush=True)
        run(MIX + ["compile", "--force"], dist, env)
        run(MIX + ["release", "--overwrite"], dist, env, scratch / "build-b.log")
        b_root = dist / "_build/prod/rel/lmx"
        plan = {}
        for app in ("lemieux", "lmx"):
            before = a_root / f"lib/{app}-0.1.0/ebin"
            after = b_root / f"lib/{app}-0.1.1/ebin"
            plan[app] = [p.stem for p in after.glob("*.beam") if p.read_bytes() != (before / p.name).read_bytes()]
        old_info = artifact_info(a_tar)
        modules = '%{' + ', '.join(app + ': [' + ', '.join(':' + json.dumps(module) for module in changed) + ']' for app, changed in plan.items()) + '}'
        target = old_info["target"]
        targets = []
        for platform in ("linux", "macos", "macos_silicon", "windows"):
            decision = '%{mode: :restart, reason: "Fixture restart path."}'
            if platform == target:
                decision = ('%{mode: :hot, reason: "Test-only version/notice changes; fixture state is unchanged.", '
                            'from_build: ' + json.dumps(old_info["build_id"]) + ', modules: ' + modules + ', '
                            'review: %{state: "Fixture state unchanged.", messages: "Messages unchanged.", '
                            'closures: "Callback refresh and soft purge tested.", rollback: "Symmetric fixture loads tested."}}')
            targets.append(json.dumps(platform) + ' => ' + decision)
        declaration = '%{schema_version: 1, version: "0.1.1", from: "0.1.0", reviewed: true, targets: %{' + ', '.join(targets) + '}}\n'
        (dist / "upgrades/0.1.1.exs").write_text(declaration)
        env["LMX_UPGRADE_FROM"] = str(a_root)
        run(MIX + ["release", "--overwrite"], dist, env, scratch / "build-relup.log")
        info = json.loads((b_root / "releases/0.1.1/release.json").read_text())
        assert info["dependencies"]["ex_ratatui"]
        assert info["native_id"] != hashlib.sha256(b"").hexdigest()
        target = info["target"]
        # Each archive is named as it is in the immutable public release.
        old = scratch / "old" / f"lmx_{target}.tar.gz"
        old.parent.mkdir()
        shutil.copy2(a_tar, old)
        new = scratch / "new" / f"lmx_{target}.tar.gz"
        new.parent.mkdir()
        shutil.copy2(dist / "_build/prod/lmx-0.1.1.tar.gz", new)
        info["sha256"] = hashlib.sha256(new.read_bytes()).hexdigest()
        qualified = scratch / "qualified"
        qualified.mkdir()
        qualify_archives(old, new, qualified, expect_hot=True, marker="[upgrade-smoke] Lemieux v0.1.1 loaded")
        exercise(old, new, info, scratch / "retained-callback", failure="callback")
        # A second update must either load safely or select the pristine full
        # candidate. Deliberately retain a version-A closure in the latter run.
        previous = scratch / "b-predecessor"
        previous.mkdir()
        with tarfile.open(new) as archive:
            archive.extractall(previous, filter="data")
        (checkout / "VERSION").write_text("0.1.2\n")
        patched(mix, '@version "0.1.1"', '@version "0.1.2"')
        patched(tui, '[upgrade-smoke]', '[upgrade-smoke-c]')
        env.pop("LMX_UPGRADE_FROM", None)
        run(MIX + ["release", "--overwrite"], dist, env, scratch / "build-c.log")
        changed = {}
        for app in ("lemieux", "lmx"):
            before = previous / f"lib/{app}-0.1.1/ebin"
            after = b_root / f"lib/{app}-0.1.2/ebin"
            changed[app] = [p.stem for p in after.glob("*.beam") if p.read_bytes() != (before / p.name).read_bytes()]
        modules = '%{' + ', '.join(app + ': [' + ', '.join(':' + json.dumps(module) for module in names) + ']' for app, names in changed.items()) + '}'
        targets = []
        for platform in ("linux", "macos", "macos_silicon", "windows"):
            decision = '%{mode: :restart, reason: "Fixture restart path."}'
            if platform == target:
                decision = ('%{mode: :hot, reason: "Test-only second update; state unchanged.", '
                            'from_build: ' + json.dumps(info["build_id"]) + ', modules: ' + modules + ', '
                            'review: %{state: "Fixture state unchanged.", messages: "Messages unchanged.", '
                            'closures: "Second soft purge and held closure fallback exercised.", rollback: "Symmetric fixture loads."}}')
            targets.append(json.dumps(platform) + ' => ' + decision)
        (dist / "upgrades/0.1.2.exs").write_text('%{schema_version: 1, version: "0.1.2", from: "0.1.1", reviewed: true, targets: %{' + ', '.join(targets) + '}}\n')
        env["LMX_UPGRADE_FROM"] = str(previous)
        run(MIX + ["release", "--overwrite"], dist, env, scratch / "build-c-relup.log")
        third = scratch / "third" / f"lmx_{target}.tar.gz"
        third.parent.mkdir()
        shutil.copy2(dist / "_build/prod/lmx-0.1.2.tar.gz", third)
        exercise(old, new, info, scratch / "consecutive-hot", following=third,
                 marker="[upgrade-smoke] Lemieux v0.1.1 loaded",
                 following_marker="[upgrade-smoke-c] Lemieux v0.1.2 loaded")
        exercise(old, new, info, scratch / "held-old-closure", following=third, hold_old_code=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--from", dest="previous", type=Path)
    parser.add_argument("--to", dest="candidate", type=Path)
    parser.add_argument("--expect-hot", action="store_true")
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    if args.previous or args.candidate:
        if not args.previous or not args.candidate:
            parser.error("both --from and --to are required")
        with workspace() as scratch:
            report = qualify_archives(args.previous.resolve(), args.candidate.resolve(), scratch, args.expect_hot)
            plan = ROOT / "dist/lmx/upgrades" / (report["to"]["version"] + ".exs")
            report["plan_sha256"] = hashlib.sha256(plan.read_bytes()).hexdigest()
            if args.report:
                args.report.write_text(json.dumps(report, indent=2) + "\n")
    else:
        if args.expect_hot or args.report:
            parser.error("artifact flags require --from and --to")
        synthetic()


if __name__ == "__main__":
    main()
