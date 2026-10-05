# The release host's tests prepare real runtimes, so the same overrides that
# the library's suite scrubs (test/test_helper.exs) must not reach them from a
# contributor's shell: with `LMX_WEB_SEARCH=brave` exported,
# jev_compaction_test.exs failed while CI, which has none, passed.
System.put_env("LMX_CONFIG", "none")
System.put_env("LMX_PROJECT_MCP", "0")

for {name, _value} <- System.get_env(),
    String.starts_with?(name, "LMX_"),
    name not in ["LMX_CONFIG", "LMX_PROJECT_MCP"],
    do: System.delete_env(name)

# Tests tagged :unix need what only Unix has: /bin/sh and POSIX signals
# (`kill`, SIGTERM traps), Unix file modes, symbolic links, `:` in PATH. The
# release workflow runs this suite on Windows too, where they cannot pass, and
# a failure there stopped every release from being assembled, not just the
# experimental Windows archive.
ExUnit.start(exclude: if(match?({:win32, _name}, :os.type()), do: [:unix], else: []))
