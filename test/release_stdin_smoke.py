"""Prove the installed launcher hands its standard input to the packaged VM.

The launcher backgrounds the release so it can forward signals, and POSIX
gives a backgrounded command /dev/null as standard input unless it redirects
its own. A regression there is invisible to every other smoke test: nothing
else pipes into `lmx`. Here a script extension's initialization reads the
whole of standard input inside the real release and refuses to load unless it
received exactly what this test piped in.
"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

SCRIPT = r'''
defmodule ReleaseStdinSmoke do
  import Kernel, except: [apply: 2]

  def init(config: %{"expected" => expected}) do
    case IO.read(:stdio, :eof) do
      ^expected -> {:ok, []}
      other -> {:error, "standard input did not reach the release: #{inspect(other)}"}
    end
  end

  def apply(harness, _state), do: harness
end
'''

EXPECTED = "piped prompt\nsecond line\n"


def main():
    binary = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix="lmx-stdin-smoke-") as scratch:
        scratch = Path(scratch)
        extension = scratch / "extension"
        extension.mkdir()
        (extension / "smoke.exs").write_text(SCRIPT)
        # A VM that dies writes erl_crash.dump into its working directory;
        # keep any such dump in the scratch directory, never the checkout.
        env = dict(os.environ, LMX_CONFIG="none", ERL_CRASH_DUMP=str(scratch / "erl_crash.dump"))
        base = [str(binary), "explain", "--config", "none", "--no-delegate", "--no-project-mcp"]
        diagnostics = subprocess.check_output(base + ["--no-user-extensions"], env=env, cwd=scratch,
                                              stdin=subprocess.DEVNULL, text=True, timeout=120)
        manifest = {"schema_version": 1, "name": "stdin-smoke", "module": "ReleaseStdinSmoke",
                    "script": "smoke.exs",
                    "versions": json.loads(diagnostics)["diagnostics"]["versions"],
                    "options": {"expected": EXPECTED}}
        (extension / "extension.json").write_text(json.dumps(manifest))
        result = subprocess.run(base + ["--extension-dir", str(extension)], env=env, cwd=scratch,
                                input=EXPECTED, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise RuntimeError(f"stdin smoke failed ({result.returncode}): {result.stderr}")
        report = json.loads(result.stdout)
        assert report["extensions"][-1]["module"] == "ReleaseStdinSmoke", report["extensions"]
        print("verified the installed launcher passes standard input to the release")


if __name__ == "__main__":
    main()
