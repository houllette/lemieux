defmodule Lemieux.CLI.HistoryLogErrorsTest do
  # `lmx log` prints an error entry as a sentence: it printed the payload as
  # an Elixir map, and for a missing key that map carried `req_llm`'s hint
  # about a `.env` file the installed lmx never reads.
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Lemieux.CLI
  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  defp log(entries, %{tmp_dir: dir}) do
    store = JSONL.new(dir)
    :ok = Store.append(store, "failed", [Entry.new(:session, %{"model" => "test:m"}) | entries])

    opts = [
      store: store,
      provider: Scripted.new([]),
      supervisor: :"lemieux_history_log_errors_#{System.unique_integer([:positive])}"
    ]

    capture_io(fn -> assert CLI.run(["log", "failed", "--sessions-dir", dir], opts) == :ok end)
  end

  test "a missing key names the variable to set, and no .env file", context do
    output =
      log(
        [
          Entry.new(:error, %{
            "category" => "other",
            "reason" =>
              ":api_key option, config :req_llm, anthropic_api_key, or ANTHROPIC_API_KEY " <>
                "env var (.env via dotenvy)",
            "request_id" => "req-1"
          })
        ],
        context
      )

    assert output =~ "error: no API key was found: set ANTHROPIC_API_KEY"
    refute output =~ "dotenvy"
    refute output =~ "%{"
  end

  test "any other error is its reason, with its category when it has one", context do
    output =
      log(
        [
          Entry.new(:error, %{"category" => "rate_limit", "reason" => "Overloaded"}),
          Entry.new(:error, %{"reason" => "compaction failed"})
        ],
        context
      )

    assert output =~ "error (rate limit): Overloaded"
    assert output =~ "error: compaction failed"
    refute output =~ "%{"
  end
end
