System.put_env("LMX_CONFIG", "none")

# The live check against a System One server on this machine runs only when
# one is named; see test/jev_compaction/local_server_test.exs.
exclude = if System.get_env("LOCAL_SYSTEM_ONE_URL"), do: [], else: [:local_system_one]
ExUnit.start(exclude: exclude)
