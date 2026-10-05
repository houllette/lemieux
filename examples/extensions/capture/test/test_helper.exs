# Personal CLI settings must never change what a deterministic test writes.
System.put_env("LMX_CONFIG", "none")

# Every session here runs against `Lemieux.Providers.Scripted`; a longer
# `assert_receive` costs nothing when the assertion passes and keeps a busy
# machine from failing a test that was going to pass.
ExUnit.start(assert_receive_timeout: 1_000)
