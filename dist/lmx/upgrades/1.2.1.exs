# Reviewed restart decision from the signed, published 1.2.0 archives.
# All four predecessor archives were verified and unpacked. The local
# Apple Silicon comparison against build
# 3847c3e7fab329a342e8848f3d940176fa2346cd23db69dca001bbae95986a71
# found two added Lemieux modules (Ixway.Capacity and Store.Memory), no removals,
# and incompatible runtime identities. ReqLLM, LLMDB, Finch and the bundled
# extension's execution plane dependencies change.
#
# Session.State adds deferred_resume, and its Compaction struct replaces
# compaction_failed? with last_failure. Questions and ToolWave coordinate the
# deferred continuation and approved results around the existing turn budget.
# A live session may have pending replies and work whose state was initialized
# with the old fields. TUI.Submission and TUI.Events replace tracked steer text
# with a pending steer keyed to a transcript entry ID. A running screen has
# the old tool state and may retain local render or effect callbacks.
#
# Restart recreates those processes and callbacks. Resume reads the durable
# transcript and retains its budget accounting. No migration of in-flight
# state or live downgrade is provided. Each final archive must qualify cold
# boot, packaged tools and old-transcript resume against its signed predecessor.
%{
  schema_version: 1,
  version: "1.2.1",
  from: "1.2.0",
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :restart,
      reason:
        "Session and TUI state and callback changes have no live migration. " <>
          "Changed provider and extension dependencies require a fresh start. " <>
          "Qualify the static-OTP Linux archive against the signed 1.2.0 Linux build."
    },
    "macos" => %{
      mode: :restart,
      reason:
        "Pending session replies and TUI steering state need fresh initialization. " <>
          "Changed provider dependencies prevent a live update. Qualify restart and " <>
          "resume using the signed Intel predecessor and the final Intel archive."
    },
    "macos_silicon" => %{
      mode: :restart,
      reason:
        "The signed predecessor and local candidate have different runtime identities. " <>
          "Two modules were added, and session and TUI state changed. Qualify restart " <>
          "and resume with the final Apple Silicon archive."
    },
    "windows" => %{
      mode: :restart,
      reason:
        "Windows uses manual restart and resume with Git Bash. Changed session and " <>
          "TUI state and dependencies require fresh initialization. Qualify cold " <>
          "boot and old-transcript resume against the signed Windows archive."
    }
  }
}
