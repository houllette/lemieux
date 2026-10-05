defmodule LemieuxTest do
  use ExUnit.Case, async: true

  alias Lemieux.Providers.Scripted
  alias Lemieux.Store.JSONL

  doctest Lemieux

  describe "version/0" do
    test "reports the version declared in mix.exs" do
      assert Lemieux.version() == Mix.Project.config()[:version]
    end

    test "is a dotted version string, so release tooling can print it" do
      assert {:ok, _version} = Version.parse(Lemieux.version())
    end
  end

  describe "start_session/1 and run/2 with nothing mounted" do
    @describetag :tmp_dir

    test "name the missing mount instead of exiting with :noproc", %{tmp_dir: tmp_dir} do
      opts = complete_options(tmp_dir, LemieuxTest.NothingMounted)

      error = assert_raise ArgumentError, fn -> Lemieux.start_session(opts) end

      assert error.message =~ "no Lemieux runtime is mounted as LemieuxTest.NothingMounted"
      assert error.message =~ "{Lemieux.Supervisor, name: LemieuxTest.NothingMounted}"

      assert_raise ArgumentError, ~r/no Lemieux runtime is mounted/, fn ->
        Lemieux.run("hello", opts)
      end
    end

    test "say when the unnamed default mount is the one missing", %{tmp_dir: tmp_dir} do
      opts = tmp_dir |> complete_options(nil) |> Keyword.delete(:supervisor)

      assert_raise ArgumentError, ~r/the default when :supervisor is not given/, fn ->
        Lemieux.start_session(opts)
      end
    end
  end

  describe "start_session/1 option checks" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp_dir} do
      runtime = Module.concat(__MODULE__, "Runtime#{System.unique_integer([:positive])}")
      start_supervised!({Lemieux.Supervisor, name: runtime})

      %{opts: complete_options(tmp_dir, runtime)}
    end

    test "the complete options start a session", %{opts: opts} do
      assert {:ok, session} = Lemieux.start_session(opts)
      assert is_pid(session)
    end

    test "a missing provider names the option and how to build one", %{opts: opts} do
      error =
        assert_raise ArgumentError, fn ->
          Lemieux.start_session(Keyword.delete(opts, :provider))
        end

      assert error.message =~ "a session needs :provider"
      assert error.message =~ "Lemieux.Providers.ReqLLM.new()"
    end

    test "a provider module given in place of a provider says to build one", %{opts: opts} do
      assert_raise ArgumentError, ~r/not the module Lemieux.Providers.ReqLLM itself/, fn ->
        Lemieux.start_session(Keyword.put(opts, :provider, Lemieux.Providers.ReqLLM))
      end
    end

    # A provider's state can hold a key; the message describes the shape only.
    test "a malformed provider is not echoed into the message", %{opts: opts} do
      error =
        assert_raise ArgumentError, fn ->
          Lemieux.start_session(Keyword.put(opts, :provider, api_key: "sk-not-a-real-key"))
        end

      assert error.message =~ ":provider must be a {module, state} pair"
      refute error.message =~ "sk-not-a-real-key"
    end

    test "a missing store names the option and how to build one", %{opts: opts} do
      assert_raise ArgumentError, ~r/a session needs :store: .*Lemieux.Store.JSONL.new/, fn ->
        Lemieux.start_session(Keyword.delete(opts, :store))
      end
    end

    test "a new session without a model says what a model looks like", %{opts: opts} do
      assert_raise ArgumentError, ~r/a new session needs :model/, fn ->
        Lemieux.start_session(Keyword.delete(opts, :model))
      end
    end

    test "a resumed session may leave the model to its transcript", %{opts: opts} do
      assert {:ok, result} = Lemieux.run("hello", Keyword.put(opts, :keep_session, false))

      resumed =
        opts
        |> Keyword.delete(:model)
        |> Keyword.put(:provider, Scripted.new([Scripted.complete("again")]))
        |> Keyword.put(:resume, result.session_id)

      assert {:ok, %{text: "again"}} = Lemieux.run("hello again", resumed)
    end

    test "resume_session/1 checks the store before reading it", %{opts: opts} do
      assert_raise ArgumentError, ~r/a session needs :store/, fn ->
        opts
        |> Keyword.delete(:store)
        |> Keyword.put(:resume, "anything")
        |> Lemieux.resume_session()
      end
    end
  end

  defp complete_options(tmp_dir, supervisor) do
    [
      supervisor: supervisor,
      provider: Scripted.new([Scripted.complete("hi")]),
      store: JSONL.new(tmp_dir),
      model: "test:model",
      tools: []
    ]
  end
end
