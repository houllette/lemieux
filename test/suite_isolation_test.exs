defmodule LemieuxTest.SuiteIsolationTest do
  @moduledoc """
  What test/test_helper.exs promises every test.

  Nine to thirteen fixture tests once passed or failed on what the person
  running the suite had in their global Git configuration: `commit.gpgsign`
  refused every fixture commit, and `core.hooksPath` ran their own hook inside
  the fixtures. A global ignore file, which no configuration names, failed five
  checkpoint tests. These pin the isolation those tests depend on, so it cannot
  quietly go away, and the guard in front of the tests that spend money.
  """

  use ExUnit.Case, async: true

  alias LemieuxTest.Spend

  describe "a fixture repository" do
    @describetag :tmp_dir

    test "sees no configuration but its own and the suite's", %{tmp_dir: dir} do
      git!(dir, ["init", "--quiet", "--initial-branch=main"])

      scopes =
        dir
        |> git!(["config", "--list", "--show-scope"])
        |> String.split("\n", trim: true)
        |> Enum.map(&(&1 |> String.split("\t") |> hd()))
        |> Enum.uniq()

      assert scopes == ["global", "local"]

      assert git!(dir, ["config", "--global", "--list"]) == """
             core.excludesfile=/dev/null
             core.attributesfile=/dev/null
             user.name=Lemieux Test
             user.email=test@lemieux.invalid
             """
    end

    # Git finds these two files without being told, under XDG_CONFIG_HOME or
    # else ~/.config, so pointing GIT_CONFIG_GLOBAL elsewhere alone leaves them
    # in force.
    test "ignores nothing and sets no attribute from the contributor's own files",
         %{tmp_dir: dir} do
      xdg = Path.join(dir, "xdg")
      File.mkdir_p!(Path.join(xdg, "git"))
      File.write!(Path.join([xdg, "git", "ignore"]), "*.txt\n")
      File.write!(Path.join([xdg, "git", "attributes"]), "*.txt diff=contributor\n")

      repository = Path.join(dir, "repository")
      File.mkdir_p!(repository)
      git!(repository, ["init", "--quiet", "--initial-branch=main"])
      File.write!(Path.join(repository, "a.txt"), "a\n")
      contributor = [env: [{"XDG_CONFIG_HOME", xdg}]]

      # check-ignore exits 1 when nothing ignores the path.
      assert git(repository, ["check-ignore", "--verbose", "a.txt"], contributor) == {"", 1}

      assert git(repository, ["check-attr", "diff", "--", "a.txt"], contributor) ==
               {"a.txt: diff: unspecified\n", 0}
    end

    test "commits without anybody's identity", %{tmp_dir: dir} do
      commit!(dir, [])

      assert git!(dir, ["log", "-1", "--format=%an <%ae> / %cn <%ce>"]) ==
               "Lemieux Test <test@lemieux.invalid> / Lemieux Test <test@lemieux.invalid>\n"
    end

    test "keeps an identity a test sets for itself", %{tmp_dir: dir} do
      commit!(dir, ["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid"])

      assert git!(dir, ["log", "-1", "--format=%an <%ae>"]) ==
               "Fixture <fixture@example.invalid>\n"
    end
  end

  # The terminal UI reads NO_COLOR from the process environment, and with it
  # set 22 tests saw the colourless theme instead of the one they assert on.
  test "the contributor's NO_COLOR does not reach the tests" do
    assert System.get_env("NO_COLOR") == nil
  end

  describe "the spend guard" do
    test "lets a run that selects no paid test start, whatever is set" do
      assert Spend.refusal([], nil, %{}) == nil
      assert Spend.refusal([:distributed, location: {"test/a_test.exs", 3}], nil, %{}) == nil
      assert Spend.refusal([], "1", %{"LEMIEUX_ALLOW_SPEND" => "1"}) == nil
    end

    test "refuses :live and :eval_live, however they are selected, unless the run allows it" do
      for include <- [[:live], [live: "true"], [:eval_live], [:distributed, eval_live: "true"]] do
        assert Spend.run?(include)
        assert Spend.refusal(include, nil, %{}) =~ "spend real money"
        assert Spend.refusal(include, "0", %{}) =~ "LEMIEUX_ALLOW_SPEND=1 mix test --only live"
        assert Spend.refusal(include, "1", %{}) == nil
      end
    end

    # req_llm copies `.env` into the environment before the helper runs, so the
    # run sees "1" either way; only the file tells the two apart.
    test "refuses an allowance that comes from .env, which would approve every later run" do
      assert Spend.refusal([:live], "1", %{"LEMIEUX_ALLOW_SPEND" => "1"}) =~
               "LEMIEUX_ALLOW_SPEND is set in the checkout's .env"
    end

    test "skips a test that spends money unless the run allows it" do
      assert Spend.skip("1") == false

      for allowed <- [nil, "", "0", "true"] do
        assert Spend.skip(allowed) =~ "LEMIEUX_ALLOW_SPEND=1"
      end
    end

    # What `mix test path:LINE` asks ExUnit for: that one test by its location,
    # which beats every exclude, `:live` among them, and selects no tag the
    # refusal above could see.
    test "a live test chosen by its line runs only when the run allows spending" do
      path = "test/lemieux/live/providers_test.exs"
      {[^path], opts} = ExUnit.Filters.parse_paths([path <> ":140"])
      include = opts[:include]
      exclude = opts[:exclude] ++ [:live, :eval_live, :distributed]
      assert Spend.refusal(include, nil, %{}) == nil

      chosen = fn tags ->
        tags = Map.merge(%{file: Path.expand(path), line: 140, describe_line: nil}, tags)
        ExUnit.Filters.eval(include, exclude, tags, [%ExUnit.Test{name: :live, tags: tags}])
      end

      assert chosen.(%{live: true}) == :ok
      assert {:skipped, reason} = chosen.(%{live: true, skip: Spend.skip(nil)})
      assert reason =~ "LEMIEUX_ALLOW_SPEND=1"
      assert chosen.(%{live: true, skip: Spend.skip("1")}) == :ok
    end

    # Read from the source, which every run has: a run of a few files never
    # compiles the live ones, so it could not ask them for their tags. Only
    # the files `mix test` loads: mix.exs's `test_ignore_filters` leaves out
    # test/package_consumer/, whose deps/ fills with other packages' .exs
    # files once scripts/check_package.sh has run there.
    test "every test tagged :live or :eval_live carries the spend skip" do
      live =
        for file <- Path.wildcard("test/**/*_test.exs"),
            not String.starts_with?(file, "test/package_consumer/"),
            {line, kinds} <- file |> File.read!() |> Code.string_to_quoted!() |> test_tags(),
            :paid in kinds,
            do: {"#{file}:#{line}", :skip in kinds}

      assert live != [], "found no live tests to check, so the scan is broken"
      unguarded = for {location, false} <- live, do: location

      assert unguarded == [],
             "tagged :live or :eval_live without skip: LemieuxTest.Spend.skip() " <>
               "(as a @tag, @describetag or @moduletag): #{inspect(unguarded)}"
    end

    # A count per file would pass a skip set on one test and :live on
    # another; what counts is what each test ends up tagged with, including
    # the provider rows a comprehension generates.
    test "the scan gives each test the tags ExUnit would" do
      source = """
      defmodule Example do
        use ExUnit.Case
        @tag :live
        test "a" do
        end

        @tag skip: LemieuxTest.Spend.skip()
        test "b" do
        end

        describe "c" do
          @describetag live: true
          @describetag skip: LemieuxTest.Spend.skip()
          test "d" do
          end
        end

        for name <- ["e1", "e2"] do
          describe name do
            @describetag :live
            test "e" do
            end
          end
        end

        @moduletag :eval_live
        test "f" do
        end

        @moduletag skip: LemieuxTest.Spend.skip()
        test "g" do
        end
      end
      """

      tests =
        for {line, kinds} <- test_tags(Code.string_to_quoted!(source)),
            do: {line, Enum.sort(kinds)}

      assert Enum.sort(tests) == [
               {4, [:paid]},
               {8, [:skip]},
               {14, [:paid, :skip]},
               {21, [:paid]},
               {27, [:paid]},
               {31, [:paid, :skip]}
             ]
    end
  end

  # `{line, kinds}` for each test in `ast`, from the tags it is defined with,
  # gathered as ExUnit.Case gathers them: the @tag values since the test
  # before it, the @describetag values so far in its describe block and the
  # @moduletag values so far in its module. A kind is :paid for :live or
  # :eval_live, and :skip for `skip: LemieuxTest.Spend.skip()`.
  defp test_tags(ast) do
    {_scope, tests} = walk(ast, %{tag: [], describetag: [], moduletag: []}, [])
    tests
  end

  defp walk({:defmodule, _meta, [_name, [do: body]]}, scope, tests) do
    {_inner, tests} = walk(body, %{tag: [], describetag: [], moduletag: []}, tests)
    {scope, tests}
  end

  defp walk({:describe, _meta, [_name, [do: body]]}, scope, tests) do
    {_inner, tests} = walk(body, %{scope | describetag: []}, tests)
    {scope, tests}
  end

  defp walk({:@, _meta, [{attribute, _, [value]}]}, scope, tests)
       when attribute in [:tag, :describetag, :moduletag],
       do: {Map.update!(scope, attribute, &(tag_kinds(value) ++ &1)), tests}

  defp walk({:test, meta, [_name | _rest]}, scope, tests) do
    kinds = Enum.uniq(scope.tag ++ scope.describetag ++ scope.moduletag)
    {%{scope | tag: []}, [{meta[:line], kinds} | tests]}
  end

  # Everything else in the order it is written, so a test generated in a
  # comprehension is seen with the tags set above it.
  defp walk({_form, _meta, arguments}, scope, tests) when is_list(arguments),
    do: walk(arguments, scope, tests)

  defp walk({left, right}, scope, tests), do: walk([left, right], scope, tests)

  defp walk(nodes, scope, tests) when is_list(nodes) do
    Enum.reduce(nodes, {scope, tests}, fn node, {scope, tests} -> walk(node, scope, tests) end)
  end

  defp walk(_leaf, scope, tests), do: {scope, tests}

  defp tag_kinds(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn
      paid when paid in [:live, :eval_live] -> [:paid]
      {paid, _value} when paid in [:live, :eval_live] -> [:paid]
      {:skip, {{:., _, [{:__aliases__, _, [:LemieuxTest, :Spend]}, :skip]}, _, []}} -> [:skip]
      _other -> []
    end)
  end

  defp commit!(dir, identity) do
    git!(dir, ["init", "--quiet", "--initial-branch=main"])
    File.write!(Path.join(dir, "a.txt"), "a\n")
    git!(dir, ["add", "a.txt"])
    git!(dir, identity ++ ["commit", "--quiet", "--message", "fixture"])
  end

  defp git!(dir, arguments) do
    {output, status} = git(dir, arguments, [])
    assert status == 0, output
    output
  end

  defp git(dir, arguments, options) do
    System.cmd("git", arguments, [cd: dir, stderr_to_stdout: true] ++ options)
  end
end
