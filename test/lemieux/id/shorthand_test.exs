defmodule Lemieux.ID.ShorthandTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.ID
  alias Lemieux.ID.Shorthand
  alias Lemieux.Store
  alias Lemieux.Store.JSONL

  # Literal old names pin both previous mappings without copying their arithmetic.
  @legacy_id "01K2QF8YV3RB4TJ6WQ0N7XZDP5"
  @legacy_two_name "dennis-iginla"
  @legacy_three_name "parent-stevens-simpson"

  # Version 3 named this id with a name version 4 withholds; version 4 redraws.
  @withheld_id "probe-2979"
  @withheld_name "cummy-burton"
  @redrawn_name "steve-stone"

  @nhl_file Path.expand("../../../lib/lemieux/id/data/nhl_players.tsv", __DIR__)
  @women_file Path.expand("../../../lib/lemieux/id/data/womens_players.tsv", __DIR__)

  defp write(store, id) do
    :ok = Store.append(store, id, [Entry.new(:user, %{"text" => "hello"})])

    id
  end

  test "the same id always has the same name" do
    id = ID.generate()

    assert Shorthand.of(id) == Shorthand.of(id)
  end

  test "names are drawn only from bundled whole player names" do
    roster = roster_names(@nhl_file) ++ roster_names(@women_file)
    names = MapSet.new(roster)

    assert MapSet.size(names) == length(roster)
    assert MapSet.size(names) == Shorthand.player_count()

    assert MapSet.member?(names, "wayne-gretzky")
    assert MapSet.member?(names, "marie-philip-poulin")
    assert MapSet.member?(names, "hayley-wickenheiser")

    for n <- 1..1_000 do
      assert MapSet.member?(names, Shorthand.of("session-#{n}"))
    end
  end

  test "fixed ids preserve the chosen complete names" do
    assert Shorthand.of(@legacy_id) == "dylan-wells"
    assert Shorthand.of("session-1") == "allyson-simpson"
    assert Shorthand.of("session-2299") == "marie-philip-poulin"
    assert Shorthand.of(@withheld_id) == @redrawn_name
    assert Shorthand.of("probe-7889") == "ray-macias"
  end

  # Changing any pool size renames ids, and so does withholding another name.
  # A new version must retain these pools.
  test "current and earlier pools stay frozen" do
    assert Shorthand.player_count() == 8_972
    assert Shorthand.alphabet_size(:first) == 1_423
    assert Shorthand.alphabet_size(:last) == 301
    assert length(Shorthand.withheld()) == 23
  end

  # The screening the withheld list came from, written down. For each term,
  # every roster slug containing it is either withheld or deliberately kept,
  # so a reviewer can see each decision, and a name dropped from the list (or
  # a term whose hits nobody judged) fails here rather than in a bug report.
  # The first pass missed `clit` and `fag`; that is why this exists.
  @screening %{
    "clit" => {~w(grant-clitsome), []},
    "fag" => {~w(samuel-fagemo), []},
    "dick" =>
      {~w(dick-behling dick-bouchard dick-butler dick-cherry dick-duff dick-gamble dick-irvin
          dick-kotanen dick-lamby dick-mattiussi dick-meissner dick-redmond dick-sarrazin
          dick-tarnstrom harry-dick),
       ~w(bill-dickie dickie-moore eldon-reddick ernie-dickens herb-dickenson jason-dickinson
          sam-dickinson)},
    "kunt" => {~w(alan-kuntz murray-kuntz), ~w(les-kuntar trevor-kuntar)},
    "cum" => {~w(cummy-burton), ~w(barry-cummins jim-cummins kyle-cumiskey tyler-cuma)},
    "cock" => {[], ~w(bob-babcock)},
    "fuc" => {[], ~w(zach-fucale)},
    "fuk" => {[], ~w(yutaka-fukufuji)},
    "willy" => {~w(willy-lindstrom), []},
    "nutt" => {~w(ron-tugnutt), []},
    "randy-wood" => {~w(randy-wood), []}
  }

  test "every screened slug was judged, and every withheld name has a screening hit" do
    roster = roster_names(@nhl_file) ++ roster_names(@women_file)
    withheld = MapSet.new(Shorthand.withheld())

    for {term, {held, kept}} <- @screening do
      hits = roster |> Enum.filter(&String.contains?(&1, term)) |> Enum.sort()

      assert hits == Enum.sort(held ++ kept), "#{term}: judge every hit"
      assert Enum.all?(held, &MapSet.member?(withheld, &1)), "#{term}: withheld"
      refute Enum.any?(kept, &MapSet.member?(withheld, &1)), "#{term}: kept"
    end

    screened =
      for {_term, {held, _kept}} <- @screening, name <- held, into: MapSet.new(), do: name

    assert screened == withheld
  end

  # The data files are the roster and nothing else: the published names and
  # league ids are gone, and the attribution travels with the data.
  test "the rosters carry slugs, attribution and the non-affiliation note" do
    for path <- [@nhl_file, @women_file] do
      lines = path |> File.read!() |> String.split("\n", trim: true)
      {header, rows} = Enum.split_with(lines, &String.starts_with?(&1, "#"))

      assert Enum.all?(rows, &(&1 =~ ~r/\A[a-z0-9]+(-[a-z0-9]+)+\z/)), path
      assert Enum.join(header, " ") =~ "Derived from public"
      assert Enum.join(header, " ") =~ "Lemieux is not affiliated with or endorsed by the NHL"
    end
  end

  test "every withheld name is a roster row, listed once" do
    roster = MapSet.new(roster_names(@nhl_file) ++ roster_names(@women_file))
    withheld = Shorthand.withheld()

    assert withheld == Enum.uniq(withheld)
    assert withheld == Enum.sort(withheld)
    assert Enum.all?(withheld, &MapSet.member?(roster, &1))
  end

  # Version 4 is version 3 with withheld names redrawn: probe until enough ids
  # whose first draw is withheld have turned up, then check each one moved to
  # the draw the documented arithmetic gives, and nothing else moved at all.
  test "a withheld name is never generated, and no other name changes" do
    withheld = MapSet.new(Shorthand.withheld())
    tables = roster_tables()

    {redrawn, kept} =
      1..30_000
      |> Enum.map(&"probe-#{&1}")
      |> Enum.split_with(&MapSet.member?(withheld, version_three(&1, tables)))

    assert length(redrawn) >= 30

    for id <- redrawn do
      name = Shorthand.of(id)

      refute MapSet.member?(withheld, name)
      assert name == version_four(id, tables, withheld)
      assert Shorthand.shorthand?(name)
    end

    assert Enum.all?(kept, &(Shorthand.of(&1) == version_three(&1, tables)))
  end

  test "freshly generated ids never get a withheld name" do
    withheld = MapSet.new(Shorthand.withheld())

    refute Enum.any?(1..2_000, fn _n -> MapSet.member?(withheld, Shorthand.of(ID.generate())) end)
  end

  test "a listed name is recognised even without a session" do
    assert Shorthand.shorthand?("wayne-gretzky")
    assert Shorthand.shorthand?("marie-philip-poulin")
    assert Shorthand.shorthand?(@legacy_two_name)
    assert Shorthand.shorthand?(@withheld_name)
    assert ID.generate() |> Shorthand.of() |> Shorthand.shorthand?()
  end

  test "the three-surname shape is still recognised and never generated" do
    assert Shorthand.shorthand?(@legacy_three_name)
    assert Shorthand.shorthand?("gretzky-fleury-orr")
    refute Shorthand.of(@legacy_id) == @legacy_three_name
  end

  test "an id is never mistaken for a name" do
    refute Shorthand.shorthand?(ID.generate())
    refute Shorthand.shorthand?("gretzky-fleury")
    refute Shorthand.shorthand?("gretzky-fleury-orr-bossy")
    refute Shorthand.shorthand?("not-a-player-surname")
    refute Shorthand.shorthand?("holden-holden")
    refute Shorthand.shorthand?(nil)
  end

  describe "resolve/2" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir}, do: %{store: JSONL.new(tmp_dir)}

    # No listing, no reads: the id path has to stay as cheap as it was before
    # names existed. A store pointed at an empty directory would find nothing
    # if it looked.
    test "an id passes straight through without consulting the store", %{store: store} do
      id = ID.generate()

      assert Shorthand.resolve(store, id) == {:ok, id}
    end

    test "a name finds the session it belongs to", %{store: store} do
      id = write(store, ID.generate())
      write(store, ID.generate())

      assert Shorthand.resolve(store, Shorthand.of(id)) == {:ok, id}
    end

    test "a two-word generated name written down before still finds its session", %{
      store: store
    } do
      write(store, @legacy_id)

      assert Shorthand.resolve(store, @legacy_two_name) == {:ok, @legacy_id}
    end

    test "a three-surname name written down before still finds its session", %{store: store} do
      write(store, @legacy_id)
      write(store, ID.generate())

      assert Shorthand.resolve(store, @legacy_three_name) == {:ok, @legacy_id}
    end

    test "a three-part player name finds its session", %{store: store} do
      write(store, "session-2299")

      assert Shorthand.resolve(store, "marie-philip-poulin") == {:ok, "session-2299"}
    end

    # The session was named under version 3 and somebody wrote that down.
    test "a withheld name still finds the session version 3 gave it to", %{store: store} do
      write(store, @withheld_id)
      write(store, ID.generate())

      assert Shorthand.resolve(store, @withheld_name) == {:ok, @withheld_id}
      assert Shorthand.resolve(store, @redrawn_name) == {:ok, @withheld_id}
    end

    test "a name for nothing stored is not found", %{store: store} do
      write(store, ID.generate())

      assert Shorthand.resolve(store, Shorthand.of(ID.generate())) == {:error, :not_found}
      assert Shorthand.resolve(store, "gretzky-fleury-orr") == {:error, :not_found}
    end

    # Two sessions can share a name, and picking one would make every name
    # untrustworthy to save the person one paste.
    test "a name two sessions share is reported rather than guessed", %{store: store} do
      [first, second] = colliding_ids()

      write(store, first)
      write(store, second)

      assert {:error, {:ambiguous, found}} = Shorthand.resolve(store, Shorthand.of(first))
      assert Enum.sort(found) == Enum.sort([first, second])
    end

    test "a player name matching an older generated name is ambiguous", %{store: store} do
      old_id = write(store, "probe-2167")
      new_id = write(store, "probe-28754")

      assert Shorthand.of(new_id) == "jackie-mcleod"
      assert {:error, {:ambiguous, found}} = Shorthand.resolve(store, "jackie-mcleod")
      assert Enum.sort(found) == Enum.sort([old_id, new_id])
    end
  end

  # The rosters are stored packed rather than as a tuple per name. Recomputing
  # every probe's name from the source files by the documented arithmetic is
  # what shows the packing moved no session to a different name.
  test "the packed rosters give every id the name the source rosters give it" do
    tables = roster_tables()
    withheld = MapSet.new(Shorthand.withheld())

    for n <- 1..5_000 do
      id = "probe-#{n}"

      assert Shorthand.of(id) == version_four(id, tables, withheld)
    end
  end

  test "every roster name is recognised, and nothing spanning two names is" do
    roster = roster_names(@nhl_file) ++ roster_names(@women_file)

    assert Enum.all?(roster, &Shorthand.shorthand?/1)
    refute Shorthand.shorthand?("wayne-gretzky\nmario-lemieux")
    refute Shorthand.shorthand?("")
    refute Shorthand.shorthand?("not-a-hockey-player-at-all")
  end

  defp roster_names(path) do
    path
    |> File.stream!()
    |> Stream.reject(&String.starts_with?(&1, "#"))
    |> Enum.map(fn line ->
      line |> String.trim_trailing() |> String.split("\t", parts: 2) |> hd()
    end)
  end

  defp roster_tables do
    {roster_names(@nhl_file) |> List.to_tuple(), roster_names(@women_file) |> List.to_tuple()}
  end

  # The documented arithmetic, written out independently of the module: one
  # draw per 64-bit word of the id's SHA-256, then of the hash of that hash.
  defp draw(value, {nhl, women}) do
    if rem(value, 8) == 0,
      do: elem(women, rem(div(value, 8), tuple_size(women))),
      else: elem(nhl, rem(div(value, 8), tuple_size(nhl)))
  end

  defp version_three(id, tables) do
    <<value::unsigned-integer-size(64), _rest::binary>> = :crypto.hash(:sha256, id)

    draw(value, tables)
  end

  defp version_four(id, tables, withheld) do
    :crypto.hash(:sha256, id)
    |> Stream.iterate(&:crypto.hash(:sha256, &1))
    |> Stream.flat_map(fn hash -> for <<word::unsigned-integer-size(64) <- hash>>, do: word end)
    |> Stream.map(&draw(&1, tables))
    |> Enum.find(&(not MapSet.member?(withheld, &1)))
  end

  # Fixed probes find a real collision in the smaller whole-name pool.
  defp colliding_ids do
    pair =
      1..2_000
      |> Enum.map(&"probe-#{&1}")
      |> Enum.group_by(&Shorthand.of/1)
      |> Enum.find_value(fn {_name, ids} -> if length(ids) > 1, do: Enum.take(ids, 2) end)

    assert [_first, _second] = pair

    pair
  end
end
