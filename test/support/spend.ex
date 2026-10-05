defmodule LemieuxTest.Spend do
  @moduledoc false

  # Tests tagged :live or :eval_live call real model providers and spend real
  # money; everything else runs against `Lemieux.Providers.Scripted` and stays
  # offline, because a suite that needed the network to go green is one people
  # stop running. Selecting the tag is one deliberate step, and it used to be
  # the only one: `.claude/settings.json` pre-approves `mix test` for Claude
  # Code, which covered `mix test --only live` too, on whichever keys the shell
  # or the checkout's `.env` held. That file now denies the usual spellings,
  # and the second step is an environment variable set for the one run.
  #
  # Not in `.env`, though: req_llm loads that file into every run started in
  # the checkout, before test/test_helper.exs can look, so a line there would
  # approve every paid run from then on, including ones nobody meant to start
  # — and it is a file a coding agent edits as readily as any other.
  @paid_tags [:live, :eval_live]

  @not_allowed """
  this run selects tests tagged :live or :eval_live. They call real model \
  providers with the keys this shell exports or the checkout's .env holds, \
  and they spend real money.

  To run them on purpose, set LEMIEUX_ALLOW_SPEND=1 on the command line for \
  the run:

      LEMIEUX_ALLOW_SPEND=1 mix test --only live

  A coding agent should not set it; ask the person you are working for.
  """

  @in_dotenv """
  LEMIEUX_ALLOW_SPEND is set in the checkout's .env. req_llm loads that file \
  into every run started in this directory, so the line approves every paid \
  run from now on, including ones nobody meant to start.

  Remove it from .env, and set it on the command line for the one run you \
  mean:

      LEMIEUX_ALLOW_SPEND=1 mix test --only live
  """

  @typedoc "ExUnit's include filters: a tag, or a tag with the value asked for."
  @type include :: [atom() | {atom(), term()}]

  @doc "Whether a run's include filters select the tests that spend money."
  @spec run?(include :: include()) :: boolean()
  def run?(include) when is_list(include), do: Enum.any?(include, &paid?/1)

  defp paid?({tag, _value}), do: tag in @paid_tags
  defp paid?(tag), do: tag in @paid_tags

  @doc """
  Why a run must not start, or `nil` when it may.

  `allowed` is `LEMIEUX_ALLOW_SPEND` as the run sees it, which includes
  whatever req_llm copied from `.env`; `dotenv` is that file's variables, so a
  value that came from there can be told apart from one set for the run.
  """
  @spec refusal(
          include :: include(),
          allowed :: String.t() | nil,
          dotenv :: %{optional(String.t()) => String.t()}
        ) :: String.t() | nil
  def refusal(include, allowed, dotenv) do
    if run?(include), do: paid_refusal(allowed, dotenv)
  end

  defp paid_refusal(_allowed, %{"LEMIEUX_ALLOW_SPEND" => _value}), do: @in_dotenv
  defp paid_refusal("1", _dotenv), do: nil
  defp paid_refusal(_allowed, _dotenv), do: @not_allowed

  @doc """
  The `:skip` tag every test tagged :live or :eval_live carries: `false` when
  the run allows spending, the reason it is skipped otherwise.

  `refusal/3` cannot see every way such a test is chosen. `mix test path:LINE`
  includes that one test by its location, which beats every exclude, so a
  live test ran with nothing selecting `:live` and nothing asking about the
  money. The keys are gone on such a run, so the hosted providers skip, but
  the Ollama row of `Lemieux.Live.ProvidersTest` needs no key: it would
  prompt whatever model a local server had loaded. A `:skip` tag is the one
  thing a location does not beat; only `--include skip` does, which is a
  deliberate step of its own.

  Read when the test module compiles, which is after test/test_helper.exs has
  taken back whatever `.env` put in the environment, so a value that came from
  there allows nothing.
  """
  @spec skip() :: false | String.t()
  def skip, do: skip(System.get_env("LEMIEUX_ALLOW_SPEND"))

  @doc "`skip/0`'s decision, for a given value of LEMIEUX_ALLOW_SPEND."
  @spec skip(allowed :: String.t() | nil) :: false | String.t()
  def skip("1"), do: false

  # Not "spends real money": the Ollama rows cost nothing, and a reason that
  # overstates is one people learn to skim.
  def skip(_allowed),
    do:
      "calls a real model provider (a paid API, or a local server's model): " <>
        "set LEMIEUX_ALLOW_SPEND=1 for the run " <>
        "(LEMIEUX_ALLOW_SPEND=1 mix test --include live PATH:LINE)"
end
