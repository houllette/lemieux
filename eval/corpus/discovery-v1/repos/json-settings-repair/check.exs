# Grader: config/settings.json must parse as strict JSON and still carry every
# configured value.
path = "config/settings.json"

fail = fn message ->
  IO.puts("check failed: " <> message)
  System.halt(1)
end

body =
  case File.read(path) do
    {:ok, body} -> body
    {:error, reason} -> fail.("cannot read #{path}: #{inspect(reason)}")
  end

settings =
  case JSON.decode(body) do
    {:ok, settings} when is_map(settings) -> settings
    {:ok, _other} -> fail.("#{path} must decode to an object")
    {:error, reason} -> fail.("#{path} is not valid JSON: #{inspect(reason)}")
  end

expected = %{
  "service" => "orders-api",
  "listen" => %{"host" => "0.0.0.0", "port" => 8080},
  "rate_limit" => %{"requests_per_minute" => 600, "burst" => 50},
  "features" => ["inventory-sync", "async-refunds", "audit-log"],
  "log_level" => "info"
}

if settings == expected do
  IO.puts("settings ok")
else
  fail.("decoded settings differ from the configured values: #{inspect(settings)}")
end
