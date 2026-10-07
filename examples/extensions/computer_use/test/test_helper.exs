System.put_env("LMX_CONFIG", "none")

# The live check against a System One server on this machine runs only when
# one is named; see test/system_one/local_server_test.exs.
local = if System.get_env("LOCAL_SYSTEM_ONE_URL"), do: [], else: [:local_system_one]
ExUnit.start(exclude: [:browser, :live | local])
