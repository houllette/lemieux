defmodule Lemieux.Environment.SandboxCredentialsTest do
  # The credential locations every sandbox hides beyond its first list: git's
  # credential store, gcloud's and the Azure CLI's directories, and the
  # sign-ins Codex and Claude Code keep beside their settings — those two as
  # single files, so the settings stay readable. Never `~/.hex/hex.config` or
  # `~/.npmrc`, which `mix deps.get` and `npm install` read.
  #
  # Built by hand under a temporary home, as `SandboxFilesTest` builds its
  # sandboxes: neither the file callbacks nor the command lines below start
  # the sandbox's executable, so this runs without Seatbelt or bubblewrap.
  use ExUnit.Case, async: true

  alias Lemieux.Environment
  alias Lemieux.Environment.Local
  alias Lemieux.Environment.Sandbox
  alias Lemieux.Environment.Sandbox.Bubblewrap
  alias Lemieux.Environment.Sandbox.Seatbelt

  @moduletag :tmp_dir

  @secrets ~w(.git-credentials .config/gcloud .azure .codex/auth.json .claude/.credentials.json)

  @files %{
    ".git-credentials" => "https://someone:token@example.com\n",
    ".config/gcloud/application_default_credentials.json" => "{}",
    ".azure/msal_token_cache.json" => "{}",
    ".codex/auth.json" => "{}",
    ".claude/.credentials.json" => "{}",
    ".codex/config.toml" => "model = \"x\"\n",
    ".claude/settings.json" => "{}",
    ".hex/hex.config" => "{}",
    ".npmrc" => "registry=https://registry.example.com/\n"
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

  test "the default list names them, and not what a build reads" do
    hidden = Sandbox.default_hidden("/home/someone")

    for relative <- @secrets, do: assert(Path.join("/home/someone", relative) in hidden)

    for relative <- ~w(.hex .hex/hex.config .npmrc .codex .claude),
        do: refute(Path.join("/home/someone", relative) in hidden)
  end

  test "the file tools refuse them, and read what sits beside them", ctx do
    for relative <- [
          ".git-credentials",
          ".config/gcloud/application_default_credentials.json",
          ".azure/msal_token_cache.json",
          ".codex/auth.json",
          ".claude/.credentials.json"
        ] do
      assert Environment.read_file({Sandbox, ctx.sandbox}, ctx.home, relative) ==
               {:error, :eacces},
             relative
    end

    for relative <- ~w(.codex/config.toml .claude/settings.json .hex/hex.config .npmrc) do
      assert {:ok, _contents} = Environment.read_file({Sandbox, ctx.sandbox}, ctx.home, relative),
             relative
    end
  end

  test "commands lose them too: bubblewrap covers each, Seatbelt denies each", ctx do
    real = &Sandbox.real(Path.join(ctx.home, &1))
    arguments = Bubblewrap.arguments(%{ctx.sandbox | backend: :bubblewrap}, ctx.home, "true")

    for file <- ~w(.git-credentials .codex/auth.json .claude/.credentials.json),
        do: assert(contains?(arguments, ["--ro-bind", "/dev/null", real.(file)]), file)

    for directory <- ~w(.config/gcloud .azure),
        do: assert(contains?(arguments, ["--tmpfs", real.(directory)]), directory)

    profile = Seatbelt.profile(ctx.sandbox, ctx.home)

    for relative <- @secrets,
        do: assert(profile =~ ~s|(subpath "#{real.(relative)}")|, relative)

    refute profile =~ ~s|(subpath "#{real.(".hex/hex.config")}")|
  end

  defp contains?(list, run) do
    list
    |> Enum.chunk_every(length(run), 1, :discard)
    |> Enum.member?(run)
  end
end
