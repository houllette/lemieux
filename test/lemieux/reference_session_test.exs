defmodule Lemieux.ReferenceSessionTest.BlockingEnvironment do
  @moduledoc false
  @behaviour Lemieux.Environment

  @impl Lemieux.Environment
  def read_file(parent, _cwd, path) do
    send(parent, {:reading, self(), path})

    receive do
      {:release, contents} -> {:ok, contents}
    end
  end

  @impl Lemieux.Environment
  def write_file(_parent, _cwd, _path, _contents), do: {:error, :enotsup}

  @impl Lemieux.Environment
  def run(_parent, _command, _opts), do: {:error, :enotsup}
end

defmodule Lemieux.ReferenceSessionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Providers.Scripted
  alias Lemieux.ReferenceSessionTest.BlockingEnvironment
  alias Lemieux.Request
  alias Lemieux.Session
  alias Lemieux.Store.JSONL

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    runtime = :"lemieux_reference_test_#{System.unique_integer([:positive])}"
    start_supervised!({Lemieux.Supervisor, name: runtime})

    %{runtime: runtime, store: JSONL.new(tmp_dir), cwd: tmp_dir}
  end

  defp start_session(context, script, opts \\ []) do
    {session, _provider} = start_scripted(context, script, opts)
    session
  end

  defp start_scripted(context, script, opts) do
    provider = Scripted.new(script)

    {:ok, session} =
      Lemieux.start_session(
        [
          supervisor: context.runtime,
          provider: provider,
          store: context.store,
          model: "test:model",
          cwd: context.cwd,
          subscriber: self()
        ] ++ opts
      )

    {session, provider}
  end

  defp user_entry(session) do
    session |> Session.snapshot() |> Map.fetch!(:entries) |> Enum.find(&(&1.type == :user))
  end

  describe "expanding @references on a prompt" do
    test "attaches what the reference names to the user entry", context do
      File.write!(Path.join(context.cwd, "a.ex"), "defmodule A do\nend\n")
      session = start_session(context, [[{:done, :stop}]])

      :ok = Session.prompt(session, "explain @a.ex")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert %Entry{payload: %{"text" => text, "attachments" => [attachment]}} =
               user_entry(session)

      assert text == "explain @a.ex"
      assert attachment["path"] == "a.ex"
      assert attachment["kind"] == "file"
      assert attachment["text"] =~ "1\tdefmodule A do"
    end

    test "writes the payload it has always written when nothing was referenced", context do
      session = start_session(context, [[{:done, :stop}]])

      :ok = Session.prompt(session, "no references here")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert %Entry{payload: payload} = user_entry(session)
      assert payload == %{"text" => "no references here"}
    end

    test "tells the model about an explicit reference it could not read", context do
      session = start_session(context, [[{:done, :stop}]])

      :ok = Session.prompt(session, "explain @lib/missing.ex")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert %Entry{payload: %{"attachments" => [attachment]}} = user_entry(session)
      assert attachment["kind"] == "error"
      assert attachment["text"] =~ ~s(error="no such file")
    end

    test "expands a follow-up as well as a prompt", context do
      File.write!(Path.join(context.cwd, "a.ex"), "hello")
      session = start_session(context, [[{:done, :stop}], [{:done, :stop}]])

      :ok = Session.prompt(session, "first")
      assert_receive {:lemieux, _, {:finished, :stop}}

      :ok = Session.follow_up(session, "now @a.ex")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Entry{payload: %{"attachments" => [attachment]}}] =
               session
               |> Session.snapshot()
               |> Map.fetch!(:entries)
               |> Enum.filter(&(&1.type == :user))

      assert attachment["path"] == "a.ex"
    end

    test "does not expand a steer, which is not on the prompt path", context do
      File.write!(Path.join(context.cwd, "a.ex"), "hello")
      session = start_session(context, [[{:done, :stop}], [{:done, :stop}]])

      :ok = Session.prompt(session, "first")
      assert_receive {:lemieux, _, {:finished, :stop}}

      :ok = Session.steer(session, "also @a.ex")
      :ok = Session.follow_up(session, "go")
      assert_receive {:lemieux, _, {:finished, :stop}}

      steered =
        session
        |> Session.snapshot()
        |> Map.fetch!(:entries)
        |> Enum.find(&(&1.type == :user and &1.payload["text"] == "also @a.ex"))

      assert steered.payload == %{"text" => "also @a.ex"}
    end
  end

  describe "what a request keeps carrying" do
    test "stops re-sending a file once newer prompts have attached their own", context do
      File.write!(Path.join(context.cwd, "a.ex"), "the first file")
      File.write!(Path.join(context.cwd, "b.ex"), "the second file")

      {session, provider} =
        start_scripted(context, [[{:done, :stop}], [{:done, :stop}]], keep_attachments: 1)

      :ok = Session.prompt(session, "explain @a.ex")
      assert_receive {:lemieux, _, {:finished, :stop}}

      :ok = Session.follow_up(session, "now @b.ex")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [_first, %Request{entries: entries}] = Scripted.requests(provider)

      assert [older, newer] =
               entries
               |> Enum.filter(&(&1.type == :user))
               |> Enum.map(&hd(&1.payload["attachments"]))

      assert older["kind"] == "elided"
      assert older["text"] =~ "read the file if you still need it"
      refute older["text"] =~ "the first file"

      assert newer["kind"] == "file"
      assert newer["text"] =~ "the second file"
    end

    test "the transcript on disk still holds what was really attached", context do
      File.write!(Path.join(context.cwd, "a.ex"), "the first file")
      File.write!(Path.join(context.cwd, "b.ex"), "the second file")

      session = start_session(context, [[{:done, :stop}], [{:done, :stop}]], keep_attachments: 1)

      :ok = Session.prompt(session, "explain @a.ex")
      assert_receive {:lemieux, _, {:finished, :stop}}
      :ok = Session.follow_up(session, "now @b.ex")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [first, _second] =
               session
               |> Session.snapshot()
               |> Map.fetch!(:entries)
               |> Enum.filter(&(&1.type == :user))

      assert hd(first.payload["attachments"])["text"] =~ "the first file"
    end
  end

  describe "ordering against the user_prompt hook" do
    test "expands a reference the hook introduced, not the one it replaced", context do
      File.write!(Path.join(context.cwd, "a.ex"), "hello")
      File.write!(Path.join(context.cwd, "b.ex"), "goodbye")

      session =
        start_session(context, [[{:done, :stop}]],
          hooks: [user_prompt: fn _prompt, _context -> {:rewrite, "look at @b.ex"} end]
        )

      :ok = Session.prompt(session, "look at @a.ex")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert %Entry{payload: %{"text" => "look at @b.ex", "attachments" => [attachment]}} =
               user_entry(session)

      assert attachment["path"] == "b.ex"
      assert attachment["text"] =~ "goodbye"
    end

    test "a denied prompt is never expanded, because it is never a prompt", context do
      session =
        start_session(context, [],
          hooks: [user_prompt: fn _prompt, _context -> {:deny, "not now"} end]
        )

      assert Session.prompt(session, "read @a.ex") == {:error, {:hook_denied, "not now"}}
      assert user_entry(session) == nil
    end
  end

  describe "refresh/1" do
    test "says nothing changed when nothing has", context do
      File.write!(Path.join(context.cwd, "a.ex"), "hello")
      session = start_session(context, [[{:done, :stop}]])

      :ok = Session.prompt(session, "explain @a.ex")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert Session.refresh(session) == {:ok, 0}

      assert [_only] =
               session
               |> Session.snapshot()
               |> Map.fetch!(:entries)
               |> Enum.filter(&(&1.type == :user))
    end

    test "re-attaches a file that moved on, as a new prompt", context do
      path = Path.join(context.cwd, "a.ex")
      File.write!(path, "the old contents")
      session = start_session(context, [[{:done, :stop}], [{:done, :stop}]])

      :ok = Session.prompt(session, "explain @a.ex")
      assert_receive {:lemieux, _, {:finished, :stop}}

      File.write!(path, "the new contents")

      assert Session.refresh(session) == {:ok, 1}
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert [first, second] =
               session
               |> Session.snapshot()
               |> Map.fetch!(:entries)
               |> Enum.filter(&(&1.type == :user))

      # The turn that was answered keeps what was really in front of the
      # model. Entries are immutable, and that is the point of them.
      assert hd(first.payload["attachments"])["text"] =~ "the old contents"

      assert second.payload["text"] =~ "have changed on disk"
      assert second.payload["text"] =~ "a.ex"
      assert hd(second.payload["attachments"])["text"] =~ "the new contents"
    end

    test "reports a file that has since been deleted", context do
      path = Path.join(context.cwd, "a.ex")
      File.write!(path, "hello")
      session = start_session(context, [[{:done, :stop}], [{:done, :stop}]])

      :ok = Session.prompt(session, "explain @a.ex")
      assert_receive {:lemieux, _, {:finished, :stop}}

      File.rm!(path)

      assert Session.refresh(session) == {:ok, 1}
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert %Entry{payload: %{"attachments" => [attachment]}} =
               session
               |> Session.snapshot()
               |> Map.fetch!(:entries)
               |> Enum.filter(&(&1.type == :user))
               |> List.last()

      assert attachment["kind"] == "error"
      assert attachment["text"] =~ ~s(error="no such file")
    end

    test "a conversation that attached nothing has nothing to refresh", context do
      session = start_session(context, [[{:done, :stop}]])

      :ok = Session.prompt(session, "no references")
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert Session.refresh(session) == {:ok, 0}
    end

    test "waits rather than racing a running turn", context do
      File.write!(Path.join(context.cwd, "a.ex"), "hello")
      session = start_session(context, [[{:delay, 200}, {:done, :stop}]])

      :ok = Session.prompt(session, "explain @a.ex")

      assert Session.refresh(session) == {:error, :busy}
      assert_receive {:lemieux, _, {:finished, :stop}}
    end
  end

  describe "expansion is not allowed to stall the session" do
    test "answers snapshots while the environment is still reading", context do
      session =
        start_session(context, [[{:done, :stop}]], environment: {BlockingEnvironment, self()})

      prompt = Task.async(fn -> Session.prompt(session, "explain @a.ex") end)

      assert_receive {:reading, reader, "a.ex"}
      assert %{status: :busy, entries: [%Entry{type: :session}]} = Session.snapshot(session)

      send(reader, {:release, "hello"})
      assert Task.await(prompt) == :ok
      assert_receive {:lemieux, _, {:finished, :stop}}

      assert %Entry{payload: %{"attachments" => [%{"text" => text}]}} = user_entry(session)
      assert text =~ "1\thello"
    end

    test "answers the blocked caller when the session is cancelled mid-expansion", context do
      session =
        start_session(context, [[{:done, :stop}]], environment: {BlockingEnvironment, self()})

      prompt = Task.async(fn -> Session.prompt(session, "explain @a.ex") end)

      assert_receive {:reading, _reader, "a.ex"}
      :ok = Session.cancel(session)

      assert Task.await(prompt) == {:error, :cancelled}
    end
  end
end
