defmodule Lemieux.ID.Shorthand do
  @moduledoc """
  A rememberable name for a session id.

  `Lemieux.ID` explains why session ids are ULIDs, and the reasoning holds:
  they sort by age, they are safe as filenames, and they survive being read
  off a terminal. What they are not is sayable. Nobody resumes
  `01K2QF8YV3RB4TJ6WQ0N7XZDP5` from memory, and the picker exists mostly
  because of that.

  So a session has a second name — the first and last name of a real hockey
  player, such as `wayne-gretzky` or `marie-philip-poulin` — and it is
  **derived from the id rather than stored beside it**. That is the decision
  worth explaining, because storing one is
  the obvious alternative:

    * There is nothing to migrate. A transcript written by an older build has
      a shorthand the moment a newer build lists it, because the name is a
      function of the filename. A stored name would have meant every session
      recorded before the feature existed being nameless forever, or a
      migration pass over `~/.lmx/sessions`.
    * The id keeps being the identity. Nothing renames a file, `list_sessions/1`
      keeps sorting oldest-first because ULIDs sort that way, and a shorthand
      that got lost is recoverable by recomputation rather than by repair.
    * The `:session` entry stays configuration. Adding a name to it would put
      a label in a payload whose every other key is something the session
      restores itself from, and `Lemieux.Session` compares that payload to
      decide whether to append a new one.

  `/name` in an interactive front end relabels the session on screen for the
  rest of that sitting. It deliberately does not reach this module: what it
  overrides is a caption, and the handle `--resume` takes tomorrow has to stay
  something any build can recompute from the id.

  ## A fixed roster of whole names

  The bundled rosters in `data/` are derived from public NHL and PWHL roster
  listings (a snapshot of 2026-09-25), plus five earlier CWHL players
  documented by the Hockey Hall of Fame. Lemieux is not affiliated with or
  endorsed by the NHL, the PWHL or the Hockey Hall of Fame. Each row is only a
  filename-safe slug: the published names and league ids the snapshot was
  taken with were dropped before the first release, because the arithmetic
  never read them and a caption has no use for them.

  The first and last names are never chosen independently. One eighth of ids
  select from the women's roster so its much shorter history is still visible
  in ordinary use. These snapshots must not be reordered or resized: the index
  is a function of the id, so even appending a row would rename existing
  sessions.

  This is a smaller name space than generated combinations. Two sessions can
  share a player name; `resolve/2` reports `{:error, {:ambiguous, ids}}` rather
  than silently opening the wrong session. The id remains accepted everywhere.

  ## Some names are withheld

  A name is printed by every `lmx run`, shown in a screen's header and pasted
  into bug reports, and a person cannot choose it: it follows from the id. So
  a slug that reads as crude out of context is never generated, however
  ordinary it is as somebody's name. `withheld/0` lists them.

  Withholding a name does not delete its row, which would move every later
  row and rename most sessions. Instead each 64-bit word of the id's SHA-256
  is one draw: a word divisible by eight picks from the women's roster, any
  other from the NHL roster, at row `div(word, 8)` modulo the roster's length.
  The name is the first draw that is not withheld. The first draw is exactly
  the one the previous version made, so a session keeps its name unless that
  name is withheld. The hash has four words; should all four land on withheld
  names, the draws continue with the words of the hash of the hash.

  The rule is about how a slug reads out of context, in a log line, and
  never about the player. A slug is withheld when a reader is likely to take
  it as crude or as a slur, whether one part reads that way, sounds that way
  or splits that way at a glance, or the parts read that way together. A
  given name or surname that only incidentally contains or resembles such a
  term reads as a name, and is kept. Every slug in both rosters has been
  screened against this rule.

  Adding a name to the list renames the sessions that drew it, so the list is
  frozen with the rosters: a change to it is a new naming version.

  ## Names written down before the shape changed still work

  The naming has had four versions, and a name any of them gave still finds
  its session:

    1. three distinct surnames, `gretzky-fleury-orr`;
    2. a generated first name and surname;
    3. a whole roster name, where every row could be drawn;
    4. a whole roster name with the withheld names redrawn (current).

  The alphabets and arithmetic of the first two remain frozen here for names
  in scripts, notes and transcripts. Version 3 differs from version 4 only on
  a withheld name, so a withheld name still resolves to the sessions that
  drew it under version 3. If a current player name also matches an older
  name for another id, resolution reports ambiguity. `of/1` only produces a
  name from the fixed roster, and never a withheld one.
  """

  alias Lemieux.Store

  @separator "-"

  # Frozen first-name alphabet from the previous two-word generator. Never
  # change its order or length: names written down under that scheme must resolve.
  @first_names ~w(
    aaron abbie abby abigail abraham ada adam addison adelaide adele adeline adrian adriana
    adrienne agnes aidan aiden aileen aimee alan alana alastair albert alberta alec alexa
    alexander alexandra alexandria alexis alfie alfred alfreda alice alicia alina alisha alison
    alistair allan allen allison alma alonzo alton alvin alyssa amanda amber amelia amos amy ana
    anastasia andre andrea andrew andy angel angela angelica angelina angelo angus anita ann anna
    annabel annabelle anne annette annie anthony antoine antonia antonio april archer archibald
    archie arden ariana ariel arlene armando arnold arthur arturo asa asher ashley ashton astrid
    aubrey audra audrey august augustine augustus aurora austin autumn ava averill avery axel
    bailey barbara barnaby barney barrett barry bart bartholomew basil beatrice beatrix beau becky
    belinda bella ben benedict benjamin bennett benny bernadette bernard bernice bertha bertram
    beryl bess bessie beth bethany betsy bette bettie betty beverly bianca bill billie billy blair
    blanche bobbie bobby bonnie boyd brad braden bradford bradley brady brandon brandy brantley
    breanna brenda brendan brennan brent brett brian briana bridget brigid brittany brock
    broderick brody bronwyn brooke brooks bruce bryan bryant bryce brynn byron cade caitlin caleb
    callie callum calvin cameron camilla camille candace candice cara carey carl carla carlos
    carlton carmen carol carole caroline carolyn carrie carson cary casey cassandra cassidy
    catherine cathy cecil cecile cecilia cedric celeste celia chad chance chandler charity
    charlene charles charlie charlotte chase chelsea cheryl chester chloe chris christa christian
    christie christina christine christopher chuck cindy claire clara clarence clarissa clark
    claude claudia clay clayton clement cleo cliff clifford clifton clint clinton clive clyde cody
    colby cole coleman colin colleen collin colton conor conrad constance cooper cora coral corbin
    cordelia corey corinne cornelius cortney cory courtney craig crawford crispin crystal curtis
    cynthia cyril cyrus dahlia daisy dale dallas dalton damian damon dan dana daniel danielle
    danny daphne darcy darius darla darlene darnell darrell darren darryl daryl dave david davis
    dawn dean deanna debbie deborah debra declan dee deirdre delia della delores demetrius denise
    dennis denver derek derrick desmond destiny devin devon dewey dexter diana diane dianne dick
    diego dillon dina dinah dixie dolores dominic dominique don donald donna donovan dora dorian
    doris dorothea dorothy dottie doug douglas doyle drew duane dudley duncan dustin dwayne dwight
    dylan earl earnest eartha ebenezer eddie eden edgar edison edith edmund edna eduardo edward
    edwin effie eileen elaine eleanor elena eli elijah elinor eliot elisa elisabeth elise eliza
    elizabeth ella ellen ellie elliot elliott ellis elmer eloise elsa elsie elton elva elvira
    elvis emerson emery emil emilia emily emma emmett emory enid enoch enrique eric erica erik
    erika erin ernest ernestine errol erwin esme esmond esperanza estelle esther ethan ethel etta
    eugene eugenia eula eunice eva evan evangeline eve evelyn everett evie ezekiel ezra fabian
    faith fannie fanny farrah fay faye federico felicia felicity felix fenton fern fernando fidel
    finbar finlay finn finnegan fiona fitzgerald fletcher fleur flora florence floyd forrest
    foster frances francesca francine franco frank frankie franklin fred freda freddie frederic
    frederick fredrick freya frieda gabriel gabriella gabrielle gail gale galen gareth garfield
    garland garret garrett garry garth gary gaspar gavin gay gayle gemma gene geneva genevieve
    geoffrey george georgia georgina gerald geraldine gerard gerry gertrude gia gideon gigi giles
    gillian gina ginger ginny giovanni gladys glen glenda glenn gloria godfrey goldie gordon grace
    gracie graham grant granville greg gregg gregory greta gretchen griffin guadalupe guillermo
    gunnar gus guy gwen gwendolyn hadley hailey hal haley hamish hank hanna hannah harlan harley
    harold harper harriet harrison harry hattie hayden hayley hazel heather hector heidi helen
    helena helene henrietta henry herbert herman hester hetty hilary hilda holden hollis holly
    homer honor hope horace horatio howard hubert hugh hugo humphrey hunter ian ida ignatius igor
    imogen ina ines inez ingrid ira irene iris irma irvin irving isaac isabel isabella isabelle
    isadora isaiah isla ismael israel ivan ivor ivy jack jackie jackson jacob jacqueline jade
    jaime jake jamal james jamie jan jane janelle janet janice janine jared jarrett jasmine jason
    jasper javier jay jayden jean jeanette jeanne jeannie jed jeff jefferson jeffrey jenna jennie
    jennifer jenny jerald jeremiah jeremy jermaine jerome jerry jess jesse jessica jessie jesus
    jewel jill jillian jim jimmie jimmy jo joan joanna joanne jocelyn jodi jody joe joel joey
    johanna john johnathan johnnie johnny jolene jon jonah jonas jonathan jordan jorge jose
    joselyn josephine josh joshua josiah joy joyce juan juanita jude judith judy jules julia
    julian juliana julie juliet juliette julius june justin justine kaitlin kaleb kara karen kari
    karin karl kassandra kate katelyn katharine katherine kathleen kathryn kathy katie katrina kay
    kayla kaylee keaton keegan keira kelsey ken kendall kendra kenneth kenny kent kermit kerry
    kevin kim kimberly kip kira kirby kirk kirsten kit kitty kris krista kristen kristi kristin
    kristina kristine kurt kyla kyle kylie kyra lacey lachlan lamar lambert lana lance landon lane
    lara larry laura laurel lauren laurence laurie laverne lavinia lawrence layla leah leanne lee
    leigh leila leland lena lenora leo leon leona leonard leonora leopold leroy lesley leslie
    lester leticia levi lewis lexi liam lila lilian lillian lillie lilly lily lincoln linda
    lindsey linus lionel lisa liza lizzie lloyd logan lois lola lonnie lora loraine lorena lorene
    loretta lori lorna lorraine lottie lou louella louis louisa louise lourdes lowell luca lucas
    lucia lucille lucinda lucy luella luis luke lula lulu luther lydia lyle lynda lyndon lynette
    lynn mabel mable mack mackenzie macy madeleine madeline madge madison mae maeve magdalene
    maggie magnus maisie malcolm mallory mamie mandy manuel mara marcella marcia marco marcus
    margaret margery margie margo marguerite maria mariah marian marianne maribel marie marietta
    marilyn marina mario marion marisa marissa maritza marjorie mark marla marlene marlon marsha
    marshall marta martha martin martina marty marvin mary maryann mason mathilda matilda matt
    matthew mattie maud maude maura maureen maurice mavis max maxine maxwell may maya mckenzie
    meagan meg megan meghan mel melanie melba melinda melissa melody melvin mercedes mercy
    meredith merle merlin merrill mervyn mia micah michael michaela michele michelle mickey miguel
    mikayla mike mildred miles millicent millie milo milton mindy minerva minnie miranda miriam
    misty mitchell moira molly mona monica monique monroe montgomery morgan morris mortimer morton
    moses muriel murray myra myrna myron myrtle nadia nadine nancy naomi natalie natasha nathan
    nathaniel neal ned neil nell nellie nelson nettie neville newton nicholas nick nicky nicola
    nicolas nicole nigel nina noah noel noelle nora norbert noreen norma norman norris norton
    octavia odell odessa olga olive oliver olivia ollie omar opal ophelia ora oren orlando orson
    orville oscar osmond oswald otis otto owen ozzie pablo paige paloma pam pamela pansy paola
    pascal pat patience patricia patrick patsy patti patty paul paula pauline pearl pedro peggy
    penelope penny percival percy pete peter petra peyton phil philip philippa phillip phoebe
    phyllis pierce pierre polly porter portia prescott preston primrose priscilla prudence quentin
    quincy quinn rachel rae rafael ralph ramona randall randolph randy raquel raul ray raymund
    reagan reba rebecca rebekah reece reed reese regina reginald rena renata rene renee reuben rex
    rhett rhoda rhonda rhys rich richie rick rickey ricky rita river robbie robert roberta robin
    rochelle rod roderick rodney rodrigo roger roland rolf roman romeo ron ronald ronnie rory rosa
    rosalie rosalind rosanna rose rosemary rosetta rosie roslyn ross rowan rowena roxanne ruben
    rudolph rudy rufus rupert russell rusty ruth ryan sabrina sadie sally salvador sam samantha
    sammy samson samuel sandra sandy santiago sara sarah saul savannah sawyer scarlett scott
    seamus sean sebastian selena selina selma serena seth seymour shane shanna shannon shari
    sharon shaun shauna shawn sheila shelby sheldon shelley shelly sheridan sherman sherri sherry
    sheryl shirley sibyl sidney siena sienna sierra silas silvia simon simone sinead skylar sofia
    solomon sonia sonny sonya sophia sophie spencer stacey stacy stanley stella stephanie stephen
    sterling steve steven stewart stuart sue sullivan summer susan susanna susie suzanne sybil
    sydney sylvester sylvia tabitha tad talia tamara tammy tania tanya tara tate taylor ted teddy
    temperance terence teresa teri terrance terrell terrence terri terry tess tessa thaddeus
    thelma theo theodora theodore theresa thomas tiana tiffany tilda tim timothy tina tobias toby
    todd tom tommie tommy toni tony tonya tracey tracy travis trent trenton trevor tricia trina
    trinity trisha tristan troy trudy tyler tyrone tyson ulysses una ursula valentina valerie van
    vance vanessa vaughn velma vera verna veronica vicki vickie victor victoria vince vincent
    viola violet virgil virginia vivian vivien wade waldo walker wallace wally walt walter wanda
    ward warren waverly wayne wendell wendy wesley whitney wilbur wilda wiley wilfred wilhelmina
    will willa willard willie willis willow wilma wilson winifred winston wyatt xavier yolanda
    yvette yvonne zachariah zachary zane zara zeke zelda zoe zora
  )

  # Frozen surname alphabet shared by the previous two-word and original
  # three-surname generators. See the module documentation for why it remains.
  @surnames ~w(
    abel aho alfredsson amonte anderson andreychuk apps armstrong arnott barber barrasso
    barzal bathgate baun belfour beliveau benn bergeron blake boeser bossy bourne bower
    brodeur broten brown bucyk bure burns byfuglien byram carpenter carter cashman chara
    cheevers chelios ciccarelli cirelli clarke coffey connor cournoyer couture couturier
    crosby dahlin danault daneyko datsyuk deadmarsh delvecchio desjardins dionne domi
    doughty draisaitl draper drury dryden duchene duff ehlers eichel elias esposito faksa
    fedorov ferguson fiala fleury foote forsberg fox francis franzen fuhr gaborik gainey
    gainor gartner geoffrion getzlaf giacomin gilbert gillies gilmour girardi giroux gomez
    granlund graves gretzky guerin hadfield hall hartnell harvey hasek hatcher havlat
    hawerchuk heatley hedberg hedman heiskanen hejduk hellebuyck hertl hextall hintz
    holmstrom horton horvat housley howe hughes hull hyman iginla jagr joseph josi kaberle
    kamensky kane kaprizov kariya karlsson keith kelly kempe kennedy keon killorn klingberg
    konecny konstantinov kopitar kovalev kozlov kreider kucherov kurri lafleur lafontaine
    laine landeskog langway lapointe larionov larkin leach leclair leetch lemieux lidstrom
    lindell lindros lindsay lowe lundqvist macleish madden mahovlich makar malkin maltby
    marchand marleau marner matthews mccarty mcdavid mcdonagh mcdonald mcleod meier messier
    mikita modano mogilny morenz mullen murphy nash necas niedermayer nieuwendyk nolan
    nurse nystrom oettinger orr osgood ovechkin palat palffy palmateer panarin pandolfo
    parent parise park pastrnak pavelski perry pettersson phillips pilote plante point
    potvin price primeau pronovost propp provorov provost quick rafalski rantanen rask
    ratelle raymond recchi redden reinhart renberg resch richard richards richter ridley
    roberts robertson robinson roenick roy sakic salming sanderson sanheim saros savard
    sawchuk scheifele schultz seabrook seguin seider selanne sergachev shanahan shore shutt
    simmonds simpson sittler slavin smith spezza staal stamkos stastny stevens subban
    sundin suter svechnikov tanguay tavares teravainen thompson thornton tikkanen tippett
    tkachuk toews trocheck trottier tucker turgeon ullman vachon vaive vasilevskiy vernon
    vezina vlasic voracek weber weight wheeler worsley yzerman zetterberg zhamnov zibanejad
    zubov zuccarello
  )

  @first_count length(@first_names)
  @surname_count length(@surnames)
  @first_lookup List.to_tuple(@first_names)
  @surname_lookup List.to_tuple(@surnames)

  @nhl_file Path.expand("data/nhl_players.tsv", __DIR__)
  @women_file Path.expand("data/womens_players.tsv", __DIR__)
  @external_resource @nhl_file
  @external_resource @women_file

  # Each roster is one newline-delimited binary and a table of where each name
  # starts, not a tuple of nine thousand binaries and a set of the same names
  # again. The tuple-and-set layout compiled to over half a megabyte of BEAM —
  # the largest module in the core library, for a caption — and every VM that
  # loaded the library paid for it. A name is found by slicing the binary at
  # two offsets, and membership is one binary search for "\nname\n". Lookup is
  # the same index arithmetic as before, so every existing name is unchanged.
  # A row is a slug alone; anything after a tab is ignored, which is how rows
  # read when they still carried the published name and league id.
  roster = fn file ->
    names =
      for line <- File.stream!(file),
          not String.starts_with?(line, "#"),
          do: line |> String.trim_trailing() |> String.split("\t", parts: 2) |> hd()

    blob = "\n" <> Enum.join(names, "\n") <> "\n"

    {starts, _next} =
      Enum.map_reduce(names, 1, fn name, start -> {start, start + byte_size(name) + 1} end)

    offsets = for start <- starts ++ [byte_size(blob)], into: <<>>, do: <<start::32>>

    {blob, offsets, length(names)}
  end

  {nhl_blob, nhl_offsets, nhl_count} = roster.(@nhl_file)
  {women_blob, women_offsets, women_count} = roster.(@women_file)

  @nhl_blob nhl_blob
  @nhl_offsets nhl_offsets
  @nhl_count nhl_count
  @women_blob women_blob
  @women_offsets women_offsets
  @women_count women_count

  # Roster names version 4 never generates; the module documentation gives
  # the rule. The screening behind each entry, and each near-miss deliberately
  # kept, is written down in test/lemieux/id/shorthand_test.exs, which fails
  # when a screened slug is neither withheld nor kept. Frozen like the rosters:
  # adding a name renames the sessions that drew it, so a change here is a new
  # naming version.
  @withheld ~w(
    alan-kuntz cummy-burton dick-behling dick-bouchard dick-butler dick-cherry dick-duff
    dick-gamble dick-irvin dick-kotanen dick-lamby dick-mattiussi dick-meissner dick-redmond
    dick-sarrazin dick-tarnstrom grant-clitsome harry-dick murray-kuntz randy-wood ron-tugnutt
    samuel-fagemo willy-lindstrom
  )

  # A misspelt entry would withhold nothing and say nothing, so every entry
  # has to be a roster row for the module to compile at all.
  for name <- @withheld,
      :binary.match(nhl_blob, "\n" <> name <> "\n") == :nomatch,
      :binary.match(women_blob, "\n" <> name <> "\n") == :nomatch do
    raise CompileError, description: "withheld name #{inspect(name)} is not a roster name"
  end

  # The original shape had three distinct surnames.
  @legacy_words 3

  @doc """
  Number of bundled whole player names: every roster row, withheld ones
  included, since a withheld row still counts in the index arithmetic.
  """
  @spec player_count() :: pos_integer()
  def player_count, do: @nhl_count + @women_count

  @doc """
  The roster names this naming version never generates, sorted.

  A withheld name still resolves to sessions that were given it by the
  previous version; see the module documentation.
  """
  @spec withheld() :: [String.t()]
  def withheld, do: Enum.sort(@withheld)

  @doc """
  How many names one half of the previous two-word alphabet has.

  Public so a test can pin both: each list is an index space, and a change to
  either length breaks previous names written down for existing sessions.
  """
  @spec alphabet_size(part :: :first | :last) :: pos_integer()
  def alphabet_size(:first), do: @first_count
  def alphabet_size(:last), do: @surname_count

  @doc """
  The shorthand for `id`.

  Deterministic, and a pure function of the string, this frozen roster and
  the withheld list — the same id has the same name on every machine using
  this naming version. SHA-256 rather than `:erlang.phash2/1`: the name ends
  up in transcripts, screenshots and bug reports, so it has to survive an OTP
  upgrade changing its hash function.
  """
  @spec of(id :: String.t()) :: String.t()
  def of(id) when is_binary(id) do
    hash = :crypto.hash(:sha256, id)

    first_permitted(hash, hash)
  end

  # One draw per 64-bit word, the first being version 3's whole name. Running
  # out of words moves on to the hash of the hash rather than to a neighbouring
  # row, which would make a withheld name's neighbour twice as common.
  defp first_permitted(<<word::unsigned-integer-size(64), rest::binary>>, hash) do
    name = draw(word)

    if withheld?(name), do: first_permitted(rest, hash), else: name
  end

  defp first_permitted(<<>>, hash) do
    next = :crypto.hash(:sha256, hash)

    first_permitted(next, next)
  end

  defp draw(value) do
    if rem(value, 8) == 0,
      do: name_at(roster(:women), div(value, 8)),
      else: name_at(roster(:nhl), div(value, 8))
  end

  # The name this id had under version 3, before any name was withheld.
  defp version_three(id), do: id |> digest() |> draw()

  for name <- @withheld do
    defp withheld?(unquote(name)), do: true
  end

  defp withheld?(_name), do: false

  # Each packed roster is named in exactly one function body, so its literal is
  # stored once in the module rather than once per use.
  defp roster(:nhl), do: {@nhl_blob, @nhl_offsets, @nhl_count}
  defp roster(:women), do: {@women_blob, @women_offsets, @women_count}

  defp name_at({blob, offsets, count}, value) do
    skip = rem(value, count) * 4
    <<_before::binary-size(^skip), start::32, next::32, _rest::binary>> = offsets
    binary_part(blob, start, next - start - 1)
  end

  # A newline in `text` could straddle two neighbouring names, so it is never
  # a name; the delimiters on both sides make every other match a whole one.
  defp roster_name?(text) do
    not String.contains?(text, "\n") and
      Enum.any?([:nhl, :women], fn roster ->
        {blob, _offsets, _count} = roster(roster)
        :binary.match(blob, "\n" <> text <> "\n") != :nomatch
      end)
  end

  @doc """
  Whether `text` is a player name on the roster or has a previous shorthand
  shape.

  A listed player name returns true even if no session has that name, and so
  does a withheld one, which version 3 gave out. Previous generated names are
  still recognised by their shape. A `Lemieux.ID` id can never satisfy either:
  Crockford base32 has no hyphen.
  """
  @spec shorthand?(text :: term()) :: boolean()
  def shorthand?(text) when is_binary(text) do
    roster_name?(text) or legacy_two_shape?(text) or
      legacy_three_shape?(text)
  end

  def shorthand?(_text), do: false

  @doc """
  Turns whatever a person typed into a session id.

  An id passes straight through, unread and unlisted, so the cost of this on
  the common path is one pattern match. Only a shorthand makes it ask the
  store what sessions exist, and even then it reads no transcripts — the name
  is computed from each id.

  `{:error, {:ambiguous, ids}}` when two stored sessions share a shorthand.
  See the moduledoc for how likely that is, and why it is not resolved by
  picking the newer one.
  """
  @spec resolve(store :: Store.t(), reference :: String.t()) ::
          {:ok, String.t()} | {:error, :not_found | {:ambiguous, [String.t()]} | term()}
  def resolve(store, reference) when is_binary(reference) do
    if shorthand?(reference) do
      resolve_shorthand(store, reference)
    else
      {:ok, reference}
    end
  end

  defp resolve_shorthand(store, reference) do
    with {:ok, ids} <- Store.list_sessions(store) do
      # An id that happens to be spelled like a name is still that id. A store's
      # keys are only strings to it, and an embedder is free to write `orr-howe-
      # gretzky.jsonl`; being unable to open it again because the resolver
      # preferred its own arithmetic would be absurd. The listing is already in
      # hand.
      if reference in ids do
        {:ok, reference}
      else
        matching_ids(ids, reference)
      end
    end
  end

  defp matching_ids(ids, reference) do
    # A current player name can also be a previous generated name. Check every
    # applicable scheme so an old name cannot silently open a new id.
    namers = namers(reference)

    matched(Enum.filter(ids, fn id -> Enum.any?(namers, &(&1.(id) == reference)) end))
  end

  # Outside the withheld list, every id version 3 named `reference` is named
  # it by version 4 too, so `of/1` alone covers both. A withheld name only
  # ever came from version 3.
  defp namers(reference) do
    [
      {roster_name?(reference) and not withheld?(reference), &of/1},
      {withheld?(reference), &version_three/1},
      {legacy_two_shape?(reference), &legacy_two/1},
      {legacy_three_shape?(reference), &legacy_three/1}
    ]
    |> Enum.filter(fn {applies?, _namer} -> applies? end)
    |> Enum.map(fn {_applies?, namer} -> namer end)
  end

  defp legacy_two_shape?(reference) do
    case String.split(reference, @separator) do
      [first, last] -> first in @first_names and last in @surnames
      _other -> false
    end
  end

  defp legacy_three_shape?(reference) do
    parts = String.split(reference, @separator)
    length(parts) == @legacy_words and Enum.all?(parts, &(&1 in @surnames))
  end

  defp matched([id]), do: {:ok, id}
  defp matched([]), do: {:error, :not_found}
  defp matched(ids), do: {:error, {:ambiguous, ids}}

  defp digest(id) do
    <<value::unsigned-integer-size(64), _rest::binary>> = :crypto.hash(:sha256, id)

    value
  end

  # The name this id had under the previous first-name/surname generator.
  defp legacy_two(id) do
    value = digest(id)

    first = elem(@first_lookup, rem(value, @first_count))
    last = elem(@surname_lookup, rem(div(value, @first_count), @surname_count))

    first <> @separator <> last
  end

  # The name this id had when a name was three surnames.
  defp legacy_three(id) do
    id |> digest() |> legacy_indexes() |> Enum.map_join(@separator, &elem(@surname_lookup, &1))
  end

  # Mixed-radix over a shrinking alphabet, which is what kept the three
  # positions distinct: `smith-smith-orr` read like a bug rather than like a
  # name. Each digit is taken against the names not yet used, then shifted
  # back into the full list by counting the ones that were.
  defp legacy_indexes(value) do
    {digits, _remaining} =
      Enum.map_reduce(0..(@legacy_words - 1), value, fn position, remaining ->
        size = @surname_count - position

        {rem(remaining, size), div(remaining, size)}
      end)

    {indexes, _taken} =
      Enum.map_reduce(digits, [], fn digit, taken ->
        index = expand(digit, Enum.sort(taken))

        {index, [index | taken]}
      end)

    indexes
  end

  # `digit` counts positions in the list with `taken` removed; walking the
  # taken indexes in ascending order and stepping past each one still at or
  # below the running value converts it back to a position in the full list.
  defp expand(digit, taken) do
    Enum.reduce(taken, digit, fn used, actual ->
      if used <= actual, do: actual + 1, else: actual
    end)
  end
end
