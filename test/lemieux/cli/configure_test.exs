defmodule Lemieux.CLI.ConfigureTest do
  use ExUnit.Case, async: false

  # Outside log capture: these tests swap the VM's log handlers and restore
  # the set they found. Under the suite's global `capture_log: true` that set
  # includes ExUnit's own capture handler, and restoring it after ExUnit had
  # removed it left a stale handler that crashed ExUnit.CaptureServer for
  # every later test.
  @moduletag capture_log: false

  alias Lemieux.CLI
  alias Lemieux.CLI.Options

  @tag :tmp_dir
  test "applies the settings needed before a terminal UI enters raw mode", %{tmp_dir: dir} do
    old_warning = Application.get_env(:req_llm, :warn_unverified_models)
    old_level = Logger.level()
    handlers = :logger.get_handler_config()

    on_exit(fn ->
      Logger.configure(level: old_level)
      for handler <- [:lmx_file, :lmx_stderr], do: :logger.remove_handler(handler)

      for %{id: id} = config <- handlers do
        _ = :logger.remove_handler(id)
        :ok = :logger.add_handler(id, config.module, config)
      end

      case old_warning do
        nil -> Application.delete_env(:req_llm, :warn_unverified_models)
        value -> Application.put_env(:req_llm, :warn_unverified_models, value)
      end
    end)

    Application.put_env(:req_llm, :warn_unverified_models, true)

    assert :ok = CLI.configure(logs: [dir: dir, stderr?: false])
    assert Logger.level() == Options.log_level()
    refute Application.fetch_env!(:req_llm, :warn_unverified_models)
    # The console handler writes into the raw-mode frame; it is gone.
    assert {:error, {:not_found, :default}} = :logger.get_handler_config(:default)
  end
end
