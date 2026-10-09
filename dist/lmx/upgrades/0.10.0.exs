# Release decision for 0.10.0 from the signed, published 0.9.1 archives.
# See upgrades/AGENTS.md and RELEASING.md, "Upgrade decisions".
#
# The inspection candidate compared with the exact macos_silicon predecessor
# adds 19 Lemieux modules, changes 60 Lemieux modules and two lmx modules,
# and fails Lmx.Release.compatible?/2. ExRatatui moves from 0.16.0 to 0.17.0
# (including its native library), ascii 0.4.1 is added, and ReqLLM, Req and
# LLMDB change. Dependency/native identities alone require restart on all targets.
#
# Source review finds additional state and callback reasons to restart:
# - Lemieux.Harness adds startup_animation; TUI terminal state adds boot steps,
#   animation settings and on_exit, and Notices replaces its overlay state with
#   transcript-row ids and expiry tokens. New callbacks cannot assume an old
#   screen has these keys or that its queued timers use the new notice shape.
# - CLI.TUI captures the exit receipt's owner/token and still installs a local
#   SIGTERM trap. A fresh launch creates both; soft purge cannot migrate retained
#   local functions in the signal server or replace their captured values.
# - A2UI installs preview/stop hooks and caches bounded diagram variants as new
#   display rows. Drawing buffers, notice rows and caches are transient; original
#   assistant source and standard stop-hook entries remain durable transcript data.
#
# No hot state/message/closure migration or hot downgrade is claimed. Restart
# archives must omit relup and advertise empty upgrade_from/hot_modules. The
# actual archive smoke exercises restart installation and old-transcript resume;
# matching-host CI and human terminal qualification remain required before tagging.
%{
  schema_version: 1,
  version: "0.10.0",
  from: "0.9.1",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "ExRatatui 0.17 changes the native terminal library, ascii 0.4.1 and new " <>
          "A2UI/TUI modules are added, and ReqLLM, Req and LLMDB change. Harness, " <>
          "boot/notice/drawing state and CLI.TUI's retained exit/SIGTERM callbacks " <>
          "require fresh initialization. Linux OTP application identities have not " <>
          "been qualified across two from-scratch builds; no hot path is declared."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "The Intel ExRatatui native library moves to 0.17; ascii 0.4.1, " <>
          "A2UI/TUI modules and changed provider dependencies require restart. " <>
          "New Harness and boot/notice/drawing state and retained CLI.TUI " <>
          "callbacks have no live migration; save the draft and resume after restart."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "The actual 0.9.1/candidate comparison adds 19 Lemieux modules and changes " <>
          "dependency/native identities (ExRatatui 0.17, ascii 0.4.1, ReqLLM, Req, " <>
          "LLMDB). New Harness and boot/notice/drawing state and retained " <>
          "CLI.TUI exit/SIGTERM callbacks have no live migration; restart and resume."
    },
    "windows" => %{
      mode: :restart,
      reason:
        "Windows always uses manual restart/resume. ExRatatui's native library, " <>
          "provider dependencies and the new A2UI/TUI modules also change; boot, " <>
          "notice and drawing state must be initialized in a fresh process."
    }
  }
}
