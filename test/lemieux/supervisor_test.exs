defmodule Lemieux.SupervisorTest do
  use ExUnit.Case, async: true

  alias Lemieux.Provider.Admission
  alias Lemieux.Supervisor, as: Sup

  describe "start_link/1" do
    test "starts under a host's supervision tree" do
      pid = start_supervised!({Sup, name: :lemieux_default_test})

      assert Process.alive?(pid)
      assert Process.whereis(:lemieux_default_test) == pid
    end

    # The whole point of taking :name rather than hardcoding one: a host that
    # wants two isolated runtimes in one VM must be able to have them.
    test "runs more than one independent runtime in the same VM" do
      first = start_supervised!({Sup, name: :lemieux_a}, id: :first)
      second = start_supervised!({Sup, name: :lemieux_b}, id: :second)

      refute first == second
      assert Process.alive?(first)
      assert Process.alive?(second)
    end
  end

  describe "children" do
    test "names every child after the mount, so two runtimes never share one" do
      start_supervised!({Sup, name: :lemieux_children})

      assert Process.whereis(Sup.registry(:lemieux_children))
      assert Process.whereis(Sup.task_supervisor(:lemieux_children))
      assert Process.whereis(Sup.background_registry(:lemieux_children))
      assert Process.whereis(Sup.background_supervisor(:lemieux_children))
      assert Process.whereis(Sup.session_supervisor(:lemieux_children))
    end
  end

  # An admission that grants everything and counts what it granted: enough to
  # show that the module a host names is the one started under the mount's
  # child name and the one sessions are pointed at.
  defmodule Always do
    @behaviour Lemieux.Provider.Admission
    use Agent

    def start_link(opts), do: Agent.start_link(fn -> 0 end, name: Keyword.fetch!(opts, :name))

    @impl Lemieux.Provider.Admission
    def checkout(ref, _key, _root_id, _estimated_tokens) do
      Agent.update(ref, &(&1 + 1))
      {:ok, {ref, make_ref()}}
    end

    @impl Lemieux.Provider.Admission
    def release(_lease), do: :ok

    @impl Lemieux.Provider.Admission
    def reconcile(_lease, _actual_tokens), do: :ok

    @impl Lemieux.Provider.Admission
    def penalize(_ref, _key, _retry_after_ms), do: :ok

    def grants(ref), do: Agent.get(ref, & &1)
  end

  describe "provider admission" do
    test "defaults to the shipped limiter under the mount's child name" do
      start_supervised!({Sup, name: :lemieux_admission_default})

      assert Sup.provider_admission(:lemieux_admission_default) ==
               {Lemieux.ProviderLimiter, Sup.provider_limiter(:lemieux_admission_default)}

      assert Process.whereis(Sup.provider_limiter(:lemieux_admission_default))
    end

    # Tests start a limiter by hand under the derived name without mounting a
    # tree; a mount nobody recorded has to answer the same default.
    test "a name that was never mounted still answers the default" do
      assert Sup.provider_admission(:lemieux_never_mounted) ==
               {Lemieux.ProviderLimiter, Sup.provider_limiter(:lemieux_never_mounted)}
    end

    test "keyword options still configure the shipped limiter" do
      start_supervised!(
        {Sup, name: :lemieux_admission_kw, provider_limiter: [max_concurrency: 1]}
      )

      assert %{max_concurrency: 1} =
               Lemieux.ProviderLimiter.snapshot(Sup.provider_limiter(:lemieux_admission_kw))
    end

    test "a host swaps the algorithm with {module, opts}, under the same child name" do
      start_supervised!({Sup, name: :lemieux_admission_custom, provider_limiter: {Always, []}})

      assert {Always, ref} = Sup.provider_admission(:lemieux_admission_custom)
      assert ref == Sup.provider_limiter(:lemieux_admission_custom)
      assert Process.whereis(ref)

      assert {:ok, _lease} = Admission.checkout({Always, ref}, :key, "root", 1)
      assert Always.grants(ref) == 1
    end

    test "rejects a provider_limiter that is neither options nor a module" do
      assert_raise ArgumentError, ~r/:provider_limiter must be/, fn ->
        Sup.start_link(name: :lemieux_admission_bad, provider_limiter: :nope)
      end
    end
  end

  describe "provider pool" do
    # Sizing the pool mutates `:req_llm`'s environment and may restart that
    # application, which a library must not do on mount. A host that still
    # asks for it here is told where the call went rather than silently
    # getting nothing.
    test "is no longer sized on mount; a caller that still asks is told what to call" do
      for option <- [provider_pool: :off, provider_pool: :size, max_concurrent_streams: 4] do
        assert_raise ArgumentError, ~r/Lemieux\.ProviderPool\.ensure\/1/, fn ->
          Sup.start_link([{:name, :lemieux_pool_option}, option])
        end
      end
    end
  end

  describe "application boundary" do
    # A `mod:` entry in mix.exs would boot a tree on load and take the
    # lifecycle decision away from the embedder. Assert its absence, so
    # restoring it fails a test rather than silently changing the contract
    # every host codes against.
    test "adding lemieux as a dependency starts nothing on its own" do
      # The key is always present in the generated .app; an absent callback
      # reads as [], and a `mod:` in mix.exs would make it
      # {Lemieux.Application, []}.
      assert Application.spec(:lemieux, :mod) == []
    end
  end
end
