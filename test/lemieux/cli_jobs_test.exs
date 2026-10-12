defmodule Lemieux.CLIJobsTest do
  # Standard error is VM-wide. Keep the worker's quiet-output assertion
  # isolated from concurrent CLI sessions that deliberately log diagnostics.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Lemieux.CLI
  alias Lemieux.CLI.Jobs.Server
  alias Lemieux.Jobs
  alias Lemieux.Providers.Scripted
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    runtime = :"cli_jobs_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})
    socket_dir = Path.join(System.tmp_dir!(), "lmx-jobs-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(socket_dir) end)
    %{runtime: runtime, dir: dir, socket_dir: socket_dir}
  end

  test "the CLI worker and separate clients submit, inspect and attach offline", context do
    provider = Scripted.new([Scripted.complete("background result")])
    owner = self()

    worker =
      Task.async(fn ->
        capture_io(:stderr, fn ->
          assert :ok =
                   CLI.run(
                     [
                       "jobs",
                       "serve",
                       "--jobs-dir",
                       context.socket_dir,
                       "--config",
                       "none",
                       "--bare",
                       "--permission-mode",
                       "off"
                     ],
                     supervisor: context.runtime,
                     cwd: context.dir,
                     provider: provider,
                     tools: [],
                     on_serve: fn server, manager -> send(owner, {:serving, server, manager}) end
                   )
        end)
      end)

    assert_receive {:serving, _server, manager}

    output =
      capture_io(fn ->
        assert :ok =
                 CLI.run(
                   [
                     "jobs",
                     "submit",
                     "--jobs-dir",
                     context.socket_dir,
                     "--max-total-requests",
                     "2",
                     "--model",
                     "test:job-model",
                     "fix offline"
                   ],
                   cwd: context.dir
                 )
      end)

    job = JSON.decode!(String.trim(output))
    assert job["intent"]["prompt"] == "fix offline"
    id = job["id"]
    {:ok, attached} = Jobs.attach(manager, id, self(), :local)

    if attached["status"] != "completed" do
      assert_receive {:lemieux_job, ^id, {:status, %{"status" => "completed"}}}
    end

    output =
      capture_io(fn ->
        assert :ok = CLI.run(["jobs", "attach", "--jobs-dir", context.socket_dir, id])
      end)

    assert %{"snapshot" => %{"result" => %{"text" => "background result"}}} =
             JSON.decode!(String.trim(output))

    assert {:ok, [%{"id" => ^id}]} =
             Server.request(Path.join(context.socket_dir, "worker.sock"), %{"op" => "list"})

    assert length(Scripted.requests(provider)) == 1
    assert hd(Scripted.requests(provider)).model == "test:job-model"
    capture_io(fn -> assert :ok = CLI.run(["jobs", "stop", "--jobs-dir", context.socket_dir]) end)
    assert Task.await(worker) == ""
  end

  test "closing an attach socket leaves the running job alive", context do
    owner = self()

    provider =
      Scripted.new([
        fn _ ->
          send(owner, :running)
          Scripted.delayed(60_000, Scripted.complete("held"))
        end
      ])

    worker =
      Task.async(fn ->
        capture_io(:stderr, fn ->
          assert :ok =
                   CLI.run(
                     [
                       "jobs",
                       "serve",
                       "--jobs-dir",
                       context.socket_dir,
                       "--config",
                       "none",
                       "--bare"
                     ],
                     supervisor: context.runtime,
                     cwd: context.dir,
                     provider: provider,
                     tools: [],
                     on_serve: fn server, manager -> send(owner, {:serving, server, manager}) end
                   )
        end)
      end)

    assert_receive {:serving, server, manager}
    path = Path.join(context.socket_dir, "worker.sock")

    {:ok, job} =
      Server.request(path, %{
        "op" => "submit",
        "intent" => %{
          "prompt" => "held",
          "cwd" => context.dir,
          "limits" => %{"max_requests" => 2}
        }
      })

    assert_receive :running

    {:ok, socket} =
      :gen_tcp.connect({:local, String.to_charlist(path)}, 0, [
        :binary,
        packet: :line,
        active: false
      ])

    :ok = :gen_tcp.send(socket, [JSON.encode!(%{"op" => "attach", "id" => job["id"]}), "\n"])
    assert {:ok, reply} = :gen_tcp.recv(socket, 0)
    assert JSON.decode!(reply)["result"]["status"] == "running"
    :gen_tcp.close(socket)
    assert {:ok, %{"status" => "running"}} = Jobs.get(manager, job["id"], :local)
    assert {:ok, "ok"} = Server.request(path, %{"op" => "cancel", "id" => job["id"]})
    GenServer.stop(server)
    assert Task.await(worker) == ""
  end

  test "invalid local JSON commands are refused without dispatch", context do
    provider = Scripted.new([])
    owner = self()

    worker =
      Task.async(fn ->
        capture_io(:stderr, fn ->
          assert :ok =
                   CLI.run(
                     ["jobs", "serve", "--jobs-dir", context.socket_dir, "--config", "none"],
                     supervisor: context.runtime,
                     provider: provider,
                     on_serve: fn server, _manager -> send(owner, {:serving, server}) end
                   )
        end)
      end)

    assert_receive {:serving, server}
    path = Path.join(context.socket_dir, "worker.sock")

    assert {:error, "invalid_job_command"} =
             Server.request(path, %{"op" => "run_code", "code" => "unsafe"})

    assert {:error, "invalid_job_intent"} =
             Server.request(path, %{"op" => "submit", "intent" => %{}})

    assert {:error, "invalid_cursor"} =
             Server.request(path, %{"op" => "list", "cursor" => %{}})

    assert {:ok, []} = Server.request(path, %{"op" => "list"})

    assert Scripted.requests(provider) == []
    GenServer.stop(server)
    assert Task.await(worker) == ""
  end
end
