defmodule Lemieux.ProviderPoolStartTypeTest do
  # Resizing the pool restarts `:req_llm`. In a release it is `:permanent`,
  # and restarting it as `:temporary` — `Application.ensure_all_started/1`'s
  # default — meant a later crash of ReqLLM's supervisor left the host running
  # with no provider pool instead of taking the node down for its supervisor.
  #
  # Exercised on an application of its own: making `:req_llm` itself
  # `:permanent` in the test VM would let any crash in it take the suite down.
  use ExUnit.Case, async: true

  alias Lemieux.ProviderPool

  # Stopping an application logs a notice per restart.
  @moduletag :capture_log

  defp library_app do
    app = :"lemieux_pool_type_#{System.unique_integer([:positive])}"

    spec =
      {:application, app,
       [
         description: ~c"an application with nothing to crash",
         vsn: ~c"1.0.0",
         modules: [],
         registered: [],
         applications: [:kernel, :stdlib]
       ]}

    :ok = :application.load(spec)

    on_exit(fn ->
      _ = Application.stop(app)
      _ = :application.unload(app)
    end)

    app
  end

  defp started_type(app) do
    :application.info() |> Keyword.fetch!(:started) |> List.keyfind(app, 0)
  end

  test "an application is restarted with the start type it had" do
    for type <- [:permanent, :transient, :temporary] do
      app = library_app()
      {:ok, _started} = Application.ensure_all_started(app, type: type)

      assert ProviderPool.restart(app) == :ok
      assert started_type(app) == {app, type}

      # Stopped here, inside the capture, as well as in `on_exit`, which runs
      # after it: three stop notices were this test's whole output in a run
      # with nothing else going on.
      assert Application.stop(app) == :ok
    end
  end

  test "an application that is not running is left alone" do
    app = library_app()

    assert ProviderPool.restart(app) == :ok
    assert started_type(app) == nil
  end
end
