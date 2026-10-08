defmodule Lemieux.Extensions.Budget do
  @moduledoc """
  Tells the model how much time and how many requests it has left, when its
  host set a limit on either.

  A host bounds a session — `:max_requests`, a `:deadline_ms` it will enforce
  itself — and nothing told the model. In one benchmark run of 0.9.1 on
  `openai_codex:gpt-6.1-sol` (#35), no transcript ever mentioned the
  deadline, and several failures came down to time. On Terminal-Bench
  `train-fasttext`, with an hour to work, the agent had a quantised model at
  62.7% validation accuracy in `/tmp` after 39 minutes, never copied a model
  to the `/app/model.bin` the task required, and started a last full-data fit
  at 60 minutes; the grader found no file. On `gpt2-codegolf`, with fifteen
  minutes, its first file was written at 860 of 900 seconds, after turns of
  up to 206 seconds spent reasoning.

  ## What the model is told, and when

  A notice starting `marker/0` is appended to a tool result: the first one
  the session produces, and the first one after each of `:thresholds`
  (default 50%, 75% and 90%) of the budget is used — of the time or of the
  requests, whichever is further along. It says what is left ("About 4
  minutes and 6 requests are left (90% used)") and asks for a valid result
  where the task requires it as soon as there is one, improved in place
  after that. The issue proposed that advice as a sentence of the default
  prompt; here it costs nothing in a session without a limit, which is most
  of them, and arrives with the numbers that make it matter.

  Each threshold is told once. The last one told is a session document
  (`lemieux.budget`), committed only against the revision it read: calls made
  together, whose hooks run at once, give one notice between them, and the
  record survives resume and fork like any other.

  ## Why a tool result

  A tool result is where the model is reading anyway, and the notice is
  then part of the transcript: recorded, replayed and resumed as it was
  sent. A note added to each request by a `prepare_next_turn` hook would be
  in no entry, so the next request's history would lack it, and a provider
  that caches a conversation's prefix up to its last message — Claude's
  rolling breakpoint — would miss every time. A stop that calls no tool ends
  the prompt, so a model that is working is calling tools, and that is when
  it needs to know.

  ## What it reads

  `Lemieux.Session.budget/1`: requests against `:max_requests`, and what is
  left of `:deadline_ms` on the session's clock. The session does not stop at
  the deadline; the host that set it does. Without either limit this sends
  nothing, and its only cost is that one call per tool result. It does not
  lower the reasoning effort as the budget runs out, which the issue
  suggested as optional: whether a model works faster that way is a
  question a host can answer for its model, with a `prepare_next_turn` hook.
  """

  @behaviour Lemieux.Extension
  import Kernel, except: [apply: 2]

  alias Lemieux.Harness
  alias Lemieux.Session

  @namespace "lemieux.budget"
  @marker "[lmx budget]"

  @type t :: %__MODULE__{thresholds: [float()], enabled: boolean()}

  defstruct thresholds: [0.0, 0.5, 0.75, 0.9], enabled: true

  @doc """
  Options: `:thresholds`, the shares of the budget (from 0 up to but not
  including 1) at which the model is told what is left, default
  `[0.0, 0.5, 0.75, 0.9]` — `0.0` being the first tool result; `:enabled`
  (default true). Unknown or malformed options are an error rather than a
  policy that silently never applies.
  """
  @impl Lemieux.Extension
  @spec init(opts :: keyword()) :: {:ok, t()} | {:error, String.t()}
  def init(opts) when is_list(opts) do
    known = __MODULE__ |> struct() |> Map.from_struct() |> Map.keys()

    case Keyword.keys(opts) -- known do
      [] -> validate(struct(__MODULE__, opts))
      unknown -> {:error, "unknown budget options: #{inspect(unknown)}"}
    end
  end

  defp validate(%__MODULE__{thresholds: thresholds, enabled: enabled} = config) do
    cond do
      not thresholds?(thresholds) ->
        {:error,
         "budget: thresholds must be a list of distinct numbers from 0 up to but not including 1"}

      not is_boolean(enabled) ->
        {:error, "budget: enabled must be true or false"}

      true ->
        {:ok, %{config | thresholds: thresholds |> Enum.map(&(&1 * 1.0)) |> Enum.sort()}}
    end
  end

  defp thresholds?([_ | _] = thresholds),
    do:
      Enum.all?(thresholds, &(is_number(&1) and &1 >= 0 and &1 < 1)) and
        length(Enum.uniq_by(thresholds, &(&1 * 1.0))) == length(thresholds)

  defp thresholds?(_thresholds), do: false

  @impl Lemieux.Extension
  def apply(%Harness{} = harness, %__MODULE__{} = config),
    do: Harness.append_hooks(harness, after_tool_call: &after_tool_call(config, &1, &2, &3))

  @impl Lemieux.Extension
  def describe(%__MODULE__{} = config),
    do: %{"thresholds" => config.thresholds, "enabled" => config.enabled}

  @doc "The prefix of every notice this extension appends to a tool result."
  @spec marker() :: String.t()
  def marker, do: @marker

  @doc "The document namespace the last threshold told is recorded under."
  @spec namespace() :: String.t()
  def namespace, do: @namespace

  @doc false
  @spec after_tool_call(config :: t(), call :: map(), result :: term(), context :: map()) ::
          :ok | {:feedback, String.t()}
  def after_tool_call(%__MODULE__{enabled: false}, _call, _result, _context), do: :ok

  def after_tool_call(%__MODULE__{} = config, _call, _result, %{session: session})
      when is_pid(session) do
    budget = Session.budget(session)

    with used when is_float(used) <- used(budget),
         {:ok, threshold} <- reached(config.thresholds, used),
         :ok <- claim(session, threshold, 2) do
      {:feedback, notice(budget, threshold, used)}
    else
      _nothing_to_tell -> :ok
    end
  end

  def after_tool_call(_config, _call, _result, _context), do: :ok

  # The share of the budget used: of the time or the requests, whichever is
  # further along, or nil when the host set neither.
  defp used(budget) do
    [time_used(budget), requests_used(budget)]
    |> Enum.reject(&is_nil/1)
    |> Enum.max(fn -> nil end)
  end

  defp time_used(%{deadline_ms: total, time_left_ms: left}) when is_integer(total),
    do: min((total - left) / total, 1.0)

  defp time_used(_budget), do: nil

  defp requests_used(%{max_requests: max, requests: requests}) when is_integer(max),
    do: min(requests / max, 1.0)

  defp requests_used(_budget), do: nil

  defp reached(thresholds, used) do
    case thresholds |> Enum.filter(&(&1 <= used)) |> List.last() do
      nil -> :none
      threshold -> {:ok, threshold}
    end
  end

  # Claims `threshold` unless it, or a later one, was told already. A conflict
  # is another call's hook committing first; read again and decide again.
  defp claim(session, threshold, attempts) do
    with {:ok, %{revision: revision, value: value}} <- Session.document(session, @namespace),
         true <- told(value) < threshold do
      case Session.put_document(session, @namespace, revision, %{"told" => threshold}) do
        {:ok, _document} ->
          :ok

        {:error, {:conflict, _current}} when attempts > 1 ->
          claim(session, threshold, attempts - 1)

        _lost ->
          :told
      end
    else
      _told -> :told
    end
  end

  defp told(%{"told" => told}) when is_number(told), do: told
  defp told(_value), do: -1

  defp notice(budget, threshold, _used) when threshold == 0.0 do
    "#{@marker} This session has #{amounts(budget)} left. When that runs out the work " <>
      "stops where it is, so put a valid result where the task requires it as soon as you " <>
      "have one, then improve it in place."
  end

  defp notice(budget, _threshold, used) do
    left = amounts(budget)

    "#{@marker} #{capitalize(left)} #{verb(budget)} left (#{round(used * 100)}% used). " <>
      "If a valid result is not yet where the task requires it, put one there now, then " <>
      "improve it in place."
  end

  defp amounts(budget), do: budget |> parts() |> Enum.join(" and ")

  defp parts(budget) do
    Enum.reject([time(budget), requests(budget)], &is_nil/1)
  end

  defp time(%{time_left_ms: nil}), do: nil

  defp time(%{time_left_ms: ms}) when ms >= 7_200_000,
    do: "about #{round(ms / 3_600_000)} hours"

  defp time(%{time_left_ms: ms}) do
    case round(ms / 60_000) do
      minutes when minutes >= 2 -> "about #{minutes} minutes"
      _one when ms >= 60_000 -> "about a minute"
      _less -> "less than a minute"
    end
  end

  defp requests(%{max_requests: nil}), do: nil

  defp requests(%{max_requests: max, requests: requests}) do
    case max(max - requests, 0) do
      1 -> "1 request"
      left -> "#{left} requests"
    end
  end

  defp verb(budget) do
    case parts(budget) do
      [single] when single in ["1 request", "about a minute", "less than a minute"] -> "is"
      _parts -> "are"
    end
  end

  defp capitalize(<<first::utf8, rest::binary>>), do: String.upcase(<<first::utf8>>) <> rest
end
