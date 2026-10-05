defmodule Lemieux.Environment.SandboxPublishCredentialsTest do
  # Two more credential files every sandbox hides: `~/.pypirc`, the token
  # `twine upload` publishes with (installing never reads it), and git's
  # credential store where XDG puts it, `~/.config/git/credentials`. That one
  # is hidden alone: `~/.config/git/config` and `ignore` beside it are what
  # every git a command runs reads.
  #
  # Built by hand under a temporary home, as `SandboxCredentialsTest` builds
  # its sandboxes, so it runs without Seatbelt or bubblewrap.
  use ExUnit.Case, async: true

  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Environment.Sandbox.Bubblewrap
  alias Lemieux.Environment.Sandbox.Seatbelt

  @moduletag :tmp_dir

  @secrets ~w(.pypirc .config/git/credentials)

  @files %{
    ".pypirc" => "[pypi]\nusername = __token__\npassword = pypi-secret\n",
    ".config/git/credentials" => "https://someone:token@example.com\n",
    ".config/git/config" => "[user]\n\tname = Someone\n",
    ".config/git/ignore" => ".DS_Store\n"
  }

  setup %{tmp_dir: home} do
    for {relative, contents} <- @files do
      path = Path.join(home, relative)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    hidden =
      home
      |> Sandbox.default_hidden()
      |> Enum.filter(&File.exists?/1)
      |> Enum.map(&Sandbox.real/1)

    sandbox = %Sandbox{
      backend: :seatbelt,
      executable: "/nonexistent/sandbox-exec",
      inner: Local,
      shell: "/bin/sh",
      hidden: hidden
    }

    %{home: home, sandbox: sandbox}
  end

  test "the default list names them, and not git's own configuration" do
    hidden = Sandbox.default_hidden("/home/someone")

    for relative <- @secrets, do: assert(Path.join("/home/someone", relative) in hidden)

    for relative <- ~w(.config .config/git .config/git/config .config/git/ignore),
        do: refute(Path.join("/home/someone", relative) in hidden)
  end

  test "the file tools refuse them, and read git's configuration beside them", ctx do
    for relative <- @secrets do
      assert Environment.read_file({Sandbox, ctx.sandbox}, ctx.home, relative) ==
               {:error, :eacces},
             relative
    end

    for relative <- ~w(.config/git/config .config/git/ignore) do
      assert {:ok, _contents} = Environment.read_file({Sandbox, ctx.sandbox}, ctx.home, relative),
             relative
    end
  end

  test "commands lose them too: bubblewrap covers each file, Seatbelt denies each", ctx do
    real = &Sandbox.real(Path.join(ctx.home, &1))
    arguments = Bubblewrap.arguments(%{ctx.sandbox | backend: :bubblewrap}, ctx.home, "true")
    profile = Seatbelt.profile(ctx.sandbox, ctx.home)

    for relative <- @secrets do
      assert contains?(arguments, ["--ro-bind", "/dev/null", real.(relative)]), relative
      assert profile =~ ~s|(subpath "#{real.(relative)}")|, relative
    end

    refute profile =~ ~s|(subpath "#{real.(".config/git")}")|
  end

  defp contains?(list, run) do
    list
    |> Enum.chunk_every(length(run), 1, :discard)
    |> Enum.member?(run)
  end
end
