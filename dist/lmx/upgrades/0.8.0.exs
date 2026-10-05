%{
  schema_version: 1,
  version: "0.8.0",
  from: nil,
  reviewed: true,
  targets: %{
    "linux" => %{
      mode: :initial,
      reason: "First public native OTP release; no prior artifact to upgrade."
    },
    "macos" => %{
      mode: :initial,
      reason: "First public native OTP release; no prior artifact to upgrade."
    },
    "macos_silicon" => %{
      mode: :initial,
      reason: "First public native OTP release; no prior artifact to upgrade."
    },
    "windows" => %{
      mode: :initial,
      reason: "First public native OTP release; manual archive installation."
    }
  }
}
