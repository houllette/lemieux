# The release decision for 0.8.1, from 0.8.0 (RELEASING.md, "Upgrade
# decisions"; the review procedure is upgrades/AGENTS.md).
#
# Restart on every platform. 0.8.1 adds a module 0.8.0 does not have —
# Lemieux.CLI.Update, behind `lmx update` — and a hot path cannot add or
# remove modules (Lmx.UpgradePlan.qualify!/3). Beyond that, the terminal UI's
# state gained two fields a running 0.8.0 screen does not hold,
# appearance.no_color and command_tab, which Lemieux.TUI.Setup.new/1 writes
# and the renderer and key handling read; a screen that took the new code
# live would read them from a state that lacks them. Lemieux.TUI's event
# handling (handle_event/2) changed as well. Nothing about restart needs a
# relup, and the archives carry none.
%{
  schema_version: 1,
  version: "0.8.1",
  from: "0.8.0",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "0.8.1 adds Lemieux.CLI.Update, a module 0.8.0 lacks, and a hot path cannot add " <>
          "modules; Lemieux.TUI's state also gained appearance.no_color and command_tab, " <>
          "which a running 0.8.0 screen does not hold. Linux stays restart until two builds " <>
          "from scratch have matched their OTP application digests."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "0.8.1 adds Lemieux.CLI.Update, a module 0.8.0 lacks, and a hot path cannot add " <>
          "modules; Lemieux.TUI's state also gained appearance.no_color and command_tab, " <>
          "which a running 0.8.0 screen does not hold."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "0.8.1 adds Lemieux.CLI.Update, a module 0.8.0 lacks, and a hot path cannot add " <>
          "modules; Lemieux.TUI's state also gained appearance.no_color and command_tab, " <>
          "which a running 0.8.0 screen does not hold."
    },
    "windows" => %{
      mode: :restart,
      reason: "Windows always restarts; the archive is installed by hand, and never hot."
    }
  }
}
