defmodule Lemieux.CLI.Learning.InstallationTest do
  use ExUnit.Case, async: true
  alias Lemieux.CLI.Learning.Installation
  alias Lemieux.Contract
  @moduletag :tmp_dir

  test "process death after intent or external install restores exact prior pointer before serving",
       %{tmp_dir: dir} do
    for failpoint <- [:after_intent, :after_install, :after_commit] do
      root = Path.join(dir, Atom.to_string(failpoint))
      File.mkdir_p!(root)
      pointer = Path.join(root, "pointer")
      journal = Path.join(root, "intent.json")
      prior = %{"id" => "old", "sha256" => Contract.sha256("old")}
      target = %{"id" => "new", "sha256" => Contract.sha256("new")}
      File.write!(pointer, JSON.encode!(prior))
      owner = self()

      install = fn reference ->
        if reference == target and failpoint == :after_intent do
          send(owner, {:held, self()})

          receive do
            :never -> :ok
          end
        end

        File.write!(pointer, JSON.encode!(reference))

        if reference == target and failpoint == :after_install do
          send(owner, {:held, self()})

          receive do
            :never -> :ok
          end
        end

        :ok
      end

      worker =
        spawn(fn ->
          assert :ok =
                   Installation.run(
                     journal,
                     prior,
                     target,
                     %{"sha256" => Contract.sha256("receipt")},
                     install,
                     fn -> :ok end
                   )

          send(owner, {:held, self()})

          receive do
            :never -> :ok
          end
        end)

      assert_receive {:held, ^worker}
      monitor = Process.monitor(worker)
      Process.exit(worker, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}

      assert {:error, :installation_requires_recovery} =
               Installation.run(
                 journal,
                 prior,
                 target,
                 %{},
                 fn _ -> flunk("replayed uncertain work") end,
                 fn -> :ok end
               )

      refute failpoint == :after_commit and JSON.decode!(File.read!(pointer)) != target
      assert {:ok, ^prior} = Installation.recover(journal, install, fn -> :ok end)
      assert JSON.decode!(File.read!(pointer)) == prior
      assert JSON.decode!(File.read!(journal))["state"] == "restored"
    end
  end

  test "revoked authority or unknown restoration blocks recovery and retains intent", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "intent.json")
    prior = %{"id" => "prior"}

    assert {:error, :installation_recovery_blocked} =
             Installation.run(
               path,
               prior,
               %{"id" => "new"},
               %{},
               fn _ -> {:error, :offline} end,
               fn -> :ok end
             )

    assert {:error, :installation_recovery_blocked} =
             Installation.recover(path, fn _ -> flunk("no authority") end, fn ->
               {:error, :revoked}
             end)

    assert File.exists?(path)

    assert {:error, :installation_recovery_blocked} =
             Installation.recover(path, fn _ -> {:error, :unknown} end, fn -> :ok end)
  end

  test "authority revoked between install and commit rolls back instead of committing", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "intent.json")
    owner = self()

    assert {:error, {:installation_rolled_back, {:error, :revoked}}} =
             Installation.run(
               path,
               %{"id" => "old"},
               %{"id" => "new"},
               %{},
               fn ref ->
                 send(owner, {:installed, ref})
                 :ok
               end,
               fn -> {:error, :revoked} end
             )

    assert_receive {:installed, %{"id" => "new"}}
    assert_receive {:installed, %{"id" => "old"}}
    refute_receive {:installed, _}, 30
  end
end
