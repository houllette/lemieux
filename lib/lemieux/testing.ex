defmodule Lemieux.Testing do
  @moduledoc """
  Deterministic host-level checks against the public Session contract.

  Pair this module with `Lemieux.Providers.Scripted`: the provider builds
  repeatable model behavior, while `prompt/3` captures the subscriber events
  and durable entries one prompt produced. The return value is ordinary data,
  so tests use their normal ExUnit assertions without Lemieux macros or a
  global mock.

      provider = Lemieux.Providers.Scripted.new([
        Lemieux.Providers.Scripted.complete("hello", fragments: ["hel", "lo"])
      ])

      {:ok, result} = Lemieux.Testing.prompt(session, "say hello")
      assert Enum.any?(result.events, &match?({:text_delta, %{text: "hel"}}, &1))
      assert List.last(result.entries).type == :assistant

  The temporary collector is an independent subscriber, so this does not
  remove or consume a host's existing subscription.
  """

  alias Lemieux.Session

  @typedoc "Observable output of one prompt."
  @type result :: %{
          events: [term()],
          entries: [Lemieux.Entry.t()],
          stop_reason: term()
        }

  @doc "Runs one prompt and returns its emitted events and resulting durable entries."
  @spec prompt(session :: Session.session(), text :: String.t(), timeout :: timeout()) ::
          {:ok, result()} | {:error, term()}
  def prompt(session, text, timeout \\ 5_000)
      when is_binary(text) and (is_integer(timeout) or timeout == :infinity) do
    parent = self()
    tag = make_ref()
    collector = spawn_link(fn -> relay(parent, tag) end)

    :ok = Session.subscribe(session, collector)

    try do
      with :ok <- Session.prompt(session, text),
           {:ok, events, stop_reason} <- collect(tag, [], timeout) do
        {:ok,
         %{
           events: events,
           entries: Session.snapshot(session).entries,
           stop_reason: stop_reason
         }}
      end
    after
      Session.unsubscribe(session, collector)
      send(collector, :stop)
    end
  end

  defp relay(parent, tag) do
    receive do
      {:lemieux, _session_id, event} ->
        send(parent, {tag, event})
        relay(parent, tag)

      :stop ->
        :ok
    end
  end

  defp collect(tag, events, timeout) do
    receive do
      {^tag, {:finished, stop_reason} = event} ->
        {:ok, Enum.reverse([event | events]), stop_reason}

      {^tag, event} ->
        collect(tag, [event | events], timeout)
    after
      timeout -> {:error, :timeout}
    end
  end
end
