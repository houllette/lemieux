defmodule Lemieux.Extensions.Workspace.PluginRemoteTest do
  @moduledoc """
  Remote catalogs and plugins the way people use them: without a cache
  directory of their own, with branches that moved past their pins, and
  offline. Each of these once stopped the session from starting.
  """
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Extensions.Workspace.Plugin.Marketplace
  alias Lemieux.Extensions.Workspace.Plugin.Remote
  alias Lemieux.Extensions.Workspace.Skill

  @moduletag :tmp_dir

  describe "the default cache" do
    # `:filename.basedir/2` answers a binary for a binary name; the default
    # went through `List.to_string/1` and every remote marketplace crashed.
    test "is a path under the user cache, not a crash" do
      root = Remote.default_cache_root()
      assert is_binary(root)
      assert String.ends_with?(root, Path.join("lemieux", "plugins"))
    end

    # The one test that uses the real per-user cache: what it checks is that
    # nothing overrides it. It creates that directory, empty, as `lmx` does
    # on its first remote marketplace; the stubbed clone writes nothing.
    test "is where a marketplace is fetched to when no cache directory is given" do
      owner = self()

      git = fn args ->
        send(owner, {:git, args})
        {"fatal: unable to access the repository", 128}
      end

      # A sentence either way, never a crash: where the user cache cannot be
      # created (a read-only home), that is the sentence.
      assert {:error, reason} =
               Marketplace.read("https://example.invalid/team/catalog.git", git: git)

      if reason =~ "could not create plugin cache" do
        assert reason =~ Remote.default_cache_root()
      else
        assert reason =~
                 "could not clone https://example.invalid/team/catalog.git (git exit 128)"

        assert_received {:git, ["clone", "--depth", "1", "--", _url, destination]}
        assert String.starts_with?(destination, Remote.default_cache_root())
      end
    end
  end

  describe "a pinned plugin" do
    test "is checked out at its pin after its branch moved on", %{tmp_dir: tmp_dir} do
      repository = Path.join(tmp_dir, "moving-plugin")
      skill(repository, "review")
      pinned = commit(repository, "pinned")

      File.rm_rf!(Path.join(repository, "skills/review"))
      skill(repository, "later")
      commit(repository, "moved on")

      catalog = catalog(tmp_dir, "moving", %{"ref" => "main", "sha" => pinned}, repository)
      cache = Path.join(tmp_dir, "cache")

      assert {:ok, plugin} = Marketplace.resolve(catalog, "moving@team", cache_dir: cache)
      assert Enum.map(plugin.skills, &Skill.qualified_name/1) == ["moving:review"]
      assert git!(plugin.root, ["rev-parse", "HEAD"]) |> String.trim() == pinned

      # The pin's checkout is the checkout from now on, without the network.
      offline = fn _args -> raise "a cached pin must not run git" end

      assert {:ok, again} =
               Marketplace.resolve(catalog, "moving@team", cache_dir: cache, git: offline)

      assert again.root == plugin.root
    end

    test "written in capitals still finds its cached checkout", %{tmp_dir: tmp_dir} do
      repository = Path.join(tmp_dir, "upper-plugin")
      skill(repository, "review")
      pinned = commit(repository, "pinned")
      cache = Path.join(tmp_dir, "cache")

      catalog =
        catalog(tmp_dir, "upper", %{"sha" => String.upcase(pinned)}, repository)

      assert {:ok, _plugin} = Marketplace.resolve(catalog, "upper@team", cache_dir: cache)

      offline = fn _args -> raise "a cached pin must not run git" end

      assert {:ok, _again} =
               Marketplace.resolve(catalog, "upper@team", cache_dir: cache, git: offline)
    end
  end

  describe "a pinned plugin whose branch is gone" do
    test "is cloned from the default branch and checked out at its pin", %{tmp_dir: tmp_dir} do
      repository = Path.join(tmp_dir, "pruned-plugin")
      skill(repository, "review")
      pinned = commit(repository, "pinned")

      catalog =
        catalog(tmp_dir, "pruned", %{"ref" => "release-1", "sha" => pinned}, repository)

      assert {:ok, plugin} =
               Marketplace.resolve(catalog, "pruned@team", cache_dir: Path.join(tmp_dir, "cache"))

      assert Enum.map(plugin.skills, &Skill.qualified_name/1) == ["pruned:review"]
      assert git!(plugin.root, ["rev-parse", "HEAD"]) |> String.trim() == pinned
    end
  end

  describe "a catalog named by its marketplace.json URL" do
    @url "https://example.test/team/marketplace.json"

    defp body(name),
      do:
        JSON.encode!(%{
          "name" => name,
          "plugins" => [%{"name" => "quality", "source" => "./plugins/quality"}]
        })

    test "is not fetched again while the copy is fresh", %{tmp_dir: tmp_dir} do
      cache = Path.join(tmp_dir, "cache")

      assert {:ok, first} =
               Marketplace.read(@url, cache_dir: cache, get: fn @url -> {:ok, 200, body("a")} end)

      unreachable = fn _url -> flunk("a fresh catalog must not be fetched") end
      assert {:ok, second} = Marketplace.read(@url, cache_dir: cache, get: unreachable)
      assert {first.name, second.name} == {"a", "a"}
      assert second.diagnostics == []
    end

    test "falls back to the copy fetched last when a refresh fails", %{tmp_dir: tmp_dir} do
      cache = Path.join(tmp_dir, "cache")
      online = fn @url -> {:ok, 200, body("team")} end
      assert {:ok, _first} = Marketplace.read(@url, cache_dir: cache, get: online)

      offline = fn @url -> {:error, :econnrefused} end

      assert {:ok, second} =
               Marketplace.read(@url, cache_dir: cache, get: offline, refresh_after_ms: 0)

      assert second.name == "team"
      assert [notice] = second.diagnostics
      assert notice =~ "marketplace team: #{@url} could not be refreshed"
      assert notice =~ "econnrefused"
    end

    test "is refetched once stale, and fails with the reason when never fetched", %{
      tmp_dir: tmp_dir
    } do
      cache = Path.join(tmp_dir, "cache")

      assert {:ok, _} =
               Marketplace.read(@url, cache_dir: cache, get: fn _ -> {:ok, 200, body("old")} end)

      assert {:ok, %{name: "new", diagnostics: []}} =
               Marketplace.read(@url,
                 cache_dir: cache,
                 get: fn _ -> {:ok, 200, body("new")} end,
                 refresh_after_ms: 0
               )

      assert {:error, reason} =
               Marketplace.read("https://example.test/other/marketplace.json",
                 cache_dir: cache,
                 get: fn _ -> {:ok, 404, ""} end
               )

      assert reason =~ "HTTP 404"
    end
  end

  describe "a catalog and an unpinned plugin" do
    test "are not fetched again while the copy is fresh", %{tmp_dir: tmp_dir} do
      source = remote_catalog(tmp_dir)
      cache = Path.join(tmp_dir, "cache")

      assert {:ok, first} = Marketplace.read(source, cache_dir: cache)

      offline = fn _args -> raise "a fresh catalog must not run git" end
      assert {:ok, second} = Marketplace.read(source, cache_dir: cache, git: offline)
      assert second.root == first.root
      assert second.diagnostics == []
    end

    test "fall back to the copy fetched last when a refresh fails", %{tmp_dir: tmp_dir} do
      source = remote_catalog(tmp_dir)
      cache = Path.join(tmp_dir, "cache")

      assert {:ok, first} = Marketplace.read(source, cache_dir: cache)

      offline = fn _args -> {"fatal: unable to access the repository", 128} end

      assert {:ok, second} =
               Marketplace.read(source, cache_dir: cache, git: offline, refresh_after_ms: 0)

      assert second.root == first.root
      assert [notice] = second.diagnostics
      assert notice =~ "marketplace team: #{source} could not be refreshed"
      assert notice =~ "using the copy fetched"

      assert {:ok, plugin} = Marketplace.resolve(second, "quality@team")
      assert Enum.map(plugin.skills, &Skill.qualified_name/1) == ["quality:review"]
    end

    test "fail with the reason when there is no copy to fall back to", %{tmp_dir: tmp_dir} do
      offline = fn _args -> {"fatal: unable to access the repository", 128} end

      assert {:error, reason} =
               Marketplace.read("file://#{tmp_dir}/nowhere",
                 cache_dir: Path.join(tmp_dir, "cache"),
                 git: offline
               )

      assert reason =~ "could not clone"
    end

    test "an unpinned remote plugin falls back the same way", %{tmp_dir: tmp_dir} do
      repository = Path.join(tmp_dir, "unpinned-plugin")
      skill(repository, "review")
      commit(repository, "fixture")
      catalog = catalog(tmp_dir, "loose", %{}, repository)
      cache = Path.join(tmp_dir, "cache")

      assert {:ok, _plugin} = Marketplace.resolve(catalog, "loose@team", cache_dir: cache)

      offline = fn _args -> {"fatal: unable to access the repository", 128} end

      assert {:ok, plugin} =
               Marketplace.resolve(catalog, "loose@team",
                 cache_dir: cache,
                 git: offline,
                 refresh_after_ms: 0
               )

      assert Enum.map(plugin.skills, &Skill.qualified_name/1) == ["loose:review"]
      assert [notice] = Enum.filter(plugin.diagnostics, &(&1 =~ "could not be refreshed"))
      assert notice =~ "plugin loose: "
    end
  end

  describe "a marketplace plugin's data directory" do
    test "is named for the plugin and its marketplace, under the directory given", %{
      tmp_dir: tmp_dir
    } do
      plugin = Path.join(tmp_dir, "plugins/kit")

      write(
        plugin,
        "hooks/hooks.json",
        JSON.encode!(%{
          "hooks" => %{"Stop" => [%{"hooks" => [%{"command" => "echo ${CLAUDE_PLUGIN_DATA}"}]}]}
        })
      )

      write(
        tmp_dir,
        ".claude-plugin/marketplace.json",
        JSON.encode!(%{
          "name" => "team",
          "plugins" => [%{"name" => "kit", "source" => "./plugins/kit"}]
        })
      )

      data_root = Path.join(tmp_dir, "plugin-data")
      assert {:ok, catalog} = Marketplace.read(tmp_dir)
      assert {:ok, loaded} = Marketplace.resolve(catalog, "kit@team", plugin_data_dir: data_root)

      assert [{:stop, command}] = loaded.hooks
      data = Path.join(data_root, "kit-team")
      assert command.command == "echo #{data}"
      assert command.env["CLAUDE_PLUGIN_DATA"] == data
    end
  end

  describe "discovery" do
    test "names an unreachable marketplace and starts without it", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(Path.join(repo, ".git"))
      offline = fn _args -> {"fatal: unable to access the repository", 128} end

      assert {:ok, workspace} =
               Discovery.discover(repo,
                 personal?: false,
                 marketplaces: ["file://#{tmp_dir}/nowhere"],
                 plugins: ["quality@nowhere"],
                 marketplace_fetch: [cache_dir: Path.join(tmp_dir, "cache"), git: offline]
               )

      assert Enum.any?(
               workspace.diagnostics,
               &(&1 =~ "marketplace file://#{tmp_dir}/nowhere was not loaded: could not clone")
             )

      assert Enum.any?(
               workspace.diagnostics,
               &(&1 =~ "plugin quality@nowhere was not loaded: no marketplace named nowhere")
             )
    end

    test "names a plugin directory it could not read and keeps the others", %{tmp_dir: tmp_dir} do
      repo = Path.join(tmp_dir, "repo")
      File.mkdir_p!(Path.join(repo, ".git"))
      good = Path.join(tmp_dir, "good")
      skill(good, "review")
      missing = Path.join(tmp_dir, "missing")

      assert {:ok, workspace} =
               Discovery.discover(repo, personal?: false, plugin_dirs: [missing, good])

      assert "good:review" in Enum.map(workspace.skills, &Skill.qualified_name/1)

      assert Enum.any?(
               workspace.diagnostics,
               &(&1 =~ "plugin #{missing} was not loaded: plugin directory does not exist")
             )
    end
  end

  defp remote_catalog(tmp_dir) do
    repository = Path.join(tmp_dir, "remote-marketplace")
    skill(Path.join(repository, "plugins/quality"), "review")

    write(
      repository,
      ".claude-plugin/marketplace.json",
      JSON.encode!(%{
        "name" => "team",
        "plugins" => [%{"name" => "quality", "source" => "./plugins/quality"}]
      })
    )

    commit(repository, "catalog")
    "file://#{repository}"
  end

  defp catalog(tmp_dir, name, pin, repository) do
    root = Path.join(tmp_dir, "catalog-#{name}")

    write(
      root,
      ".claude-plugin/marketplace.json",
      JSON.encode!(%{
        "name" => "team",
        "plugins" => [
          %{
            "name" => name,
            "source" => Map.merge(%{"source" => "url", "url" => "file://#{repository}"}, pin)
          }
        ]
      })
    )

    assert {:ok, catalog} = Marketplace.read(root)
    catalog
  end

  defp skill(plugin, name) do
    write(
      plugin,
      "skills/#{name}/SKILL.md",
      "---\nname: #{name}\ndescription: Use #{name} when it applies.\n---\nbody"
    )
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  defp commit(repository, message) do
    File.mkdir_p!(repository)

    unless File.dir?(Path.join(repository, ".git")),
      do: git!(repository, ["init", "-b", "main"])

    git!(repository, ["add", "-A", "."])

    git!(repository, [
      "-c",
      "user.name=Lemieux",
      "-c",
      "user.email=lmx@example.test",
      "commit",
      "-m",
      message
    ])

    repository |> git!(["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(repository, args) do
    {output, status} = System.cmd("git", ["-C", repository | args], stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end
