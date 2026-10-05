defmodule Lemieux.ProviderPoolTest do
  use ExUnit.Case, async: false

  alias Lemieux.ProviderPool

  # Not async, and every case restores what it changed: the pool is global to
  # the VM, which is the whole reason this module is careful about touching it.
  setup do
    size = Application.get_env(:req_llm, :stream_pool_size)
    count = Application.get_env(:req_llm, :stream_pool_count)
    finch = Application.get_env(:req_llm, :finch)
    sized? = :persistent_term.get({ProviderPool, :sized}, false)

    on_exit(fn ->
      restore(:stream_pool_size, size)
      restore(:stream_pool_count, count)
      restore(:finch, finch)
      :persistent_term.put({ProviderPool, :sized}, sized?)
    end)

    ProviderPool.forget()
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:req_llm, key)
  defp restore(key, value), do: Application.put_env(:req_llm, key, value)

  describe "required/1" do
    test "sizes for the children a runtime admits and the parents that own them" do
      # The default admission ceiling is eight children; a parent is streaming
      # its own turn while each of them streams theirs.
      assert ProviderPool.required([]) == 16
      assert ProviderPool.required(subagents: [max_active_runtime: 3]) == 6
    end

    test "a host that knows better overrides the derivation" do
      assert ProviderPool.required(max_concurrent_streams: 40) == 40

      assert ProviderPool.required(
               subagents: [max_active_runtime: 3],
               max_concurrent_streams: 40
             ) == 40
    end
  end

  describe "ensure/1" do
    test "leaves a pool that is already big enough alone" do
      Application.put_env(:req_llm, :stream_pool_size, 32)
      Application.put_env(:req_llm, :stream_pool_count, 8)

      assert ProviderPool.ensure(streams: 16) == {:ok, :sufficient}
      assert Application.get_env(:req_llm, :stream_pool_size) == 32
    end

    test "aggregate capacity does not hide a one-connection pool collision" do
      Application.put_env(:req_llm, :stream_pool_size, 1)
      Application.put_env(:req_llm, :stream_pool_count, 8)

      assert ProviderPool.ensure(streams: 2) == {:ok, :resized}
      assert Application.get_env(:req_llm, :stream_pool_size) == 2
    end

    test "never touches a pool the host configured itself" do
      Application.put_env(:req_llm, :stream_pool_size, 1)
      Application.put_env(:req_llm, :finch, name: ReqLLM.Finch, pools: %{default: [size: 1]})

      assert ProviderPool.ensure(streams: 16) == {:ok, :host_configured}
      assert Application.get_env(:req_llm, :stream_pool_size) == 1
    end

    test "can be declined outright" do
      Application.put_env(:req_llm, :stream_pool_size, 1)

      assert ProviderPool.ensure(streams: 16, mode: :off) == {:ok, :disabled}
      assert Application.get_env(:req_llm, :stream_pool_size) == 1
    end

    test "sizes each pool for the whole concurrency, and only once per VM" do
      Application.put_env(:req_llm, :stream_pool_size, 1)
      Application.put_env(:req_llm, :stream_pool_count, 8)

      assert ProviderPool.ensure(streams: 12) == {:ok, :resized}
      assert Application.get_env(:req_llm, :stream_pool_size) == 12
      assert ProviderPool.capacity() == 96

      # A second runtime that wants more does not restart the dependency under
      # the first one's in-flight requests.
      Application.put_env(:req_llm, :stream_pool_size, 1)
      assert ProviderPool.ensure(streams: 200) == {:ok, :already_sized}
      assert Application.get_env(:req_llm, :stream_pool_size) == 1
    end

    # The sizing used to happen in `Lemieux.Supervisor.init/1`. It mutates
    # another application's environment and may restart it, which a library
    # must not do underneath the host that mounted it; the host calls
    # `ensure/1` before mounting, or decides not to.
    test "mounting a runtime leaves the pool alone, however much concurrency it declares" do
      Application.put_env(:req_llm, :stream_pool_size, 1)
      Application.put_env(:req_llm, :stream_pool_count, 8)
      name = :"lemieux_pool_test_#{System.unique_integer([:positive])}"

      assert {:ok, _pid} =
               start_supervised(
                 {Lemieux.Supervisor, name: name, subagents: [max_active_runtime: 6]}
               )

      assert Application.get_env(:req_llm, :stream_pool_size) == 1
      refute :persistent_term.get({ProviderPool, :sized}, false)
    end
  end

  describe "the lmx host" do
    # `lmx` is a host like any other, so it makes the call the supervisor no
    # longer makes — once, in the setup shared by the release and the Mix
    # entry points, before anything has mounted or started `:req_llm`'s pool.
    # Outside log capture: this test swaps the VM's log handlers and restores
    # the set it found. Under the suite's global `capture_log: true` that set
    # includes ExUnit's own capture handler, and restoring it after ExUnit had
    # removed it left a stale handler that crashed ExUnit.CaptureServer for
    # every later test.
    @tag capture_log: false
    test "sizes the pool from CLI.configure/0, for the default concurrency" do
      Application.put_env(:req_llm, :stream_pool_size, 1)
      Application.put_env(:req_llm, :stream_pool_count, 8)
      level = Logger.level()
      handlers = :logger.get_handler_config()

      # `configure/1` also replaces the VM's console log handler with a file
      # (`Lemieux.CLI.Logs`): no file here, and the suite's handlers back.
      on_exit(fn ->
        Logger.configure(level: level)
        for handler <- [:lmx_file, :lmx_stderr], do: :logger.remove_handler(handler)

        for %{id: id} = config <- handlers do
          _ = :logger.remove_handler(id)
          :ok = :logger.add_handler(id, config.module, config)
        end
      end)

      assert :ok = Lemieux.CLI.configure(logs: [dir: nil, stderr?: false])

      # Eight children by default and a parent for each: sixteen streams.
      assert Application.get_env(:req_llm, :stream_pool_size) == ProviderPool.required()
      assert ProviderPool.capacity() >= 16
    end
  end

  test "capacity/0 reads the configured pool and refuses to guess at nonsense" do
    Application.put_env(:req_llm, :stream_pool_size, 4)
    Application.put_env(:req_llm, :stream_pool_count, 8)
    assert ProviderPool.capacity() == 32

    Application.put_env(:req_llm, :stream_pool_size, :lots)
    assert ProviderPool.capacity() == 0
  end
end
