"""Exercise a built lmx binary's real extension loader without model calls.

Run: python3 test/release_extension_smoke.py dist/lmx/_build/prod/rel/lmx/bin/lmx
Build on the matching host/toolchain first; this test never downloads code.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def report_from(stdout):
    return json.loads(stdout)


def main():
    root = Path(__file__).resolve().parents[1]
    binary = Path(sys.argv[1]).resolve()
    pins = dict(line.split() for line in (root / ".tool-versions").read_text().splitlines())
    with tempfile.TemporaryDirectory(prefix="lmx-extension-smoke-") as scratch:
        scratch = Path(scratch)
        extension = scratch / "extension"
        extension.mkdir()
        (extension / "extension.exs").write_text('''
defmodule NativeExtensionSmoke do
  import Kernel, except: [apply: 2]
  def apply(harness, _) do
    harness = Lemieux.Harness.update_tools(harness, fn tools ->
      Lemieux.Tool.decorate(tools, %{"bash" => &Lemieux.Tool.Override.new!(&1,
        digest: "native-smoke-v1", after: fn result, _, _ -> result end)})
    end)
    %{harness | max_requests: 7}
  end
end
''')
        manifest = {"schema_version": 1, "name": "native-smoke",
                    "module": "NativeExtensionSmoke", "script": "extension.exs",
                    "versions": {"lemieux": (root / "VERSION").read_text().strip(),
                                 "elixir": pins["elixir"].split("-otp-")[0],
                                 "otp": pins["erlang"].split(".")[0]}}
        (extension / "extension.json").write_text(json.dumps(manifest))
        env = dict(os.environ, LMX_CONFIG="none")
        command = [str(binary), "explain", "--config", "none", "--no-delegate", "--no-project-mcp",
                   "--sessions-dir", str(scratch / "sessions"),
                   "--extension-dir", str(extension)]
        result = subprocess.run(command, env=env, cwd=scratch, capture_output=True, text=True, timeout=90)
        if result.returncode:
            raise RuntimeError(result.stderr)
        report = report_from(result.stdout)
        assert report["settings"]["max_requests"] == 7, report
        bash = next(tool for tool in report["tools"] if tool["name"] == "bash")
        assert bash["implementation"] == ["Lemieux.Tool.Override", "Lemieux.Tools.Bash"]
        assert report["extensions"][-1]["module"] == "NativeExtensionSmoke"
        result = subprocess.run(command + ["--no-user-extensions"], env=env, cwd=scratch,
                                capture_output=True, text=True, timeout=90, check=True)
        recovered = report_from(result.stdout)
        # Recovery disables user extensions while retaining the shipped recipe.
        expected = [extension for extension in report["extensions"]
                    if extension["module"] != "NativeExtensionSmoke"]
        assert recovered["extensions"] == expected
        recovered_bash = next(tool for tool in recovered["tools"] if tool["name"] == "bash")
        assert recovered_bash["implementation"] == ["Lemieux.Tools.Bash"]
        assert not list((scratch / "sessions").glob("*.jsonl"))
        print("verified native extension loading, decoration, diagnostics and recovery")


if __name__ == "__main__":
    main()
