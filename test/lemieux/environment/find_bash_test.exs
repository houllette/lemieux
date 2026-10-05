defmodule Lemieux.Environment.FindBashTest do
  # Which bash commands run under. The Windows rules are decided by a function
  # given the machine as data, so they are tested wherever the suite runs.
  use ExUnit.Case, async: true

  alias Lemieux.Environment.Local

  @wsl "C:\\Windows\\System32\\bash.exe"
  @store_alias "C:\\Users\\me\\AppData\\Local\\Microsoft\\WindowsApps\\bash.exe"

  defp machine(fields) do
    executables = Keyword.get(fields, :path, %{})
    files = MapSet.new(Keyword.get(fields, :files, []))
    env = Keyword.get(fields, :env, %{})
    exec_path = Keyword.get(fields, :git_exec_path)

    %{
      executable: &Map.get(executables, &1),
      env: &Map.get(env, &1),
      file?: &MapSet.member?(files, &1),
      git_exec_path: fn -> exec_path end
    }
  end

  test "on this machine it finds the shell the suite's own commands run under" do
    case :os.type() do
      {:unix, _} ->
        assert {:ok, path} = Local.find_bash()
        assert path in [System.find_executable("bash"), System.find_executable("sh")]

      {:win32, _} ->
        assert {:ok, path} = Local.find_bash()
        refute String.downcase(path) =~ "system32"
    end
  end

  describe "elsewhere than Windows" do
    test "bash on PATH, then sh, then nothing" do
      both = machine(path: %{"bash" => "/usr/bin/bash", "sh" => "/bin/sh"})
      assert Local.find_bash({:unix, :linux}, both) == {:ok, "/usr/bin/bash"}

      only_sh = machine(path: %{"sh" => "/bin/sh"})
      assert Local.find_bash({:unix, :linux}, only_sh) == {:ok, "/bin/sh"}

      assert Local.find_bash({:unix, :darwin}, machine([])) == :error
    end
  end

  describe "on Windows" do
    test "Git for Windows at its standard location wins over any bash on PATH" do
      probe =
        machine(
          path: %{"bash" => "C:/msys64/usr/bin/bash.exe"},
          env: %{"ProgramFiles" => "C:/Program Files"},
          files: ["C:/Program Files/Git/bin/bash.exe"]
        )

      assert Local.find_bash({:win32, :nt}, probe) == {:ok, "C:/Program Files/Git/bin/bash.exe"}
    end

    test "a Git installed elsewhere is found from git --exec-path" do
      probe =
        machine(
          git_exec_path: "D:/tools/PortableGit/mingw64/libexec/git-core",
          files: ["D:/tools/PortableGit/usr/bin/bash.exe"]
        )

      assert Local.find_bash({:win32, :nt}, probe) ==
               {:ok, "D:/tools/PortableGit/usr/bin/bash.exe"}
    end

    test "WSL's bash.exe is never the answer, wherever PATH puts it" do
      for wsl <- [@wsl, @store_alias, "c:/windows/system32/BASH.EXE"] do
        assert Local.find_bash({:win32, :nt}, machine(path: %{"bash" => wsl})) == :error
      end
    end

    test "another bash on PATH is used when there is no Git for Windows" do
      probe = machine(path: %{"bash" => "C:/msys64/usr/bin/bash.exe"})

      assert Local.find_bash({:win32, :nt}, probe) == {:ok, "C:/msys64/usr/bin/bash.exe"}
    end

    test "a per-user Git install is found too" do
      probe =
        machine(
          env: %{"LOCALAPPDATA" => "C:/Users/me/AppData/Local"},
          files: ["C:/Users/me/AppData/Local/Programs/Git/bin/bash.exe"]
        )

      assert Local.find_bash({:win32, :nt}, probe) ==
               {:ok, "C:/Users/me/AppData/Local/Programs/Git/bin/bash.exe"}
    end
  end

  test "WSL's launcher is recognised by its location, in any case or separator" do
    assert Local.wsl_bash?(@wsl)
    assert Local.wsl_bash?(@store_alias)
    assert Local.wsl_bash?("C:/WINDOWS/Sysnative/bash.exe")
    refute Local.wsl_bash?("C:/Program Files/Git/bin/bash.exe")
    refute Local.wsl_bash?("/usr/bin/bash")
  end
end
