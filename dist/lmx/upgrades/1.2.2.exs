# Restart review against the signed 1.2.1 archives.
# JSV and IDNA change in the standalone runtime. Lemieux.Provider.Priority and
# the terminal access, priority and resume pickers add modules. TUI session
# views and resume callbacks have new fields, and pending tool and MCP requests
# use updated ownership and correlation rules. Restart rebuilds the session and
# terminal state before a saved transcript is resumed.
#
# The Apple Silicon inspection build had a different runtime identity from
# predecessor 5a7f2b43b1f0d36906b97a56d0f2d3ce48724a7d9871303298f01fb9d47443b6
# and added five Lemieux modules. Each final archive qualifies restart and
# transcript resume against its signed predecessor.
%{
  schema_version: 1,
  version: "1.2.2",
  from: "1.2.1",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "The JSV and IDNA updates change the Linux runtime dependency identity. " <>
          "New terminal and priority modules need a fresh start."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "The Intel archive changes runtime dependencies. Restart initializes the " <>
          "new access-program fields and resume picker callbacks."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "New terminal and priority modules and changed runtime dependencies require " <>
          "fresh initialization before resuming a saved session."
    },
    "windows" => %{
      mode: :restart,
      reason:
        "Windows uses manual restart and resume. The runtime dependency and terminal " <>
          "state changes are picked up when the new archive starts."
    }
  }
}
