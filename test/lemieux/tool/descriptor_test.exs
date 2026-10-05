defmodule Lemieux.Tool.DescriptorTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor

  defmodule TicketReader do
    @moduledoc false
    @behaviour Tool

    @impl Tool
    def name, do: "ticket_read"
    @impl Tool
    def description, do: "Reads one ticket."
    @impl Tool
    def schema, do: %{"type" => "object", "required" => ["id"]}
    @impl Tool
    def run(%{"id" => id}, _context), do: {:ok, "ticket #{id}"}
  end

  test "wraps a legacy tool in a stable version-one contract" do
    descriptor = Tool.descriptor(TicketReader)
    snapshot = Descriptor.to_map(descriptor)

    assert descriptor.executor == TicketReader
    assert snapshot["descriptor_version"] == 1
    assert snapshot["identity"]["name"] == "ticket_read"
    assert snapshot["identity"]["canonical_name"] == "host/ticket_read"
    assert snapshot["origin"]["type"] == "host_module"
    assert snapshot["interface"]["input_schema"] == TicketReader.schema()
    assert byte_size(snapshot["identity"]["implementation_digest"]) == 64
    assert byte_size(snapshot["digest"]) == 64
    assert Descriptor.to_map(Tool.descriptor(TicketReader)) == snapshot
  end

  test "a host can declare provenance, effects, policy, output and runtime metadata" do
    descriptor =
      Descriptor.new(TicketReader,
        identity: %{"namespace" => "acme", "contract_version" => "2026-08-16"},
        origin: %{"type" => "hex", "package" => "acme_tickets", "version" => "1.2.3"},
        interface: %{"output_schema" => %{"type" => "object"}},
        effects: %{"class" => "read", "resource_types" => ["ticket"]},
        policy: %{"approval" => "never"},
        runtime: %{
          "timeout_ms" => 2_000,
          "max_output_bytes" => 4_000,
          "concurrency" => %{"class" => "resource", "resource_key" => "tickets"}
        }
      )

    assert Tool.name(descriptor) == "ticket_read"
    assert descriptor.identity["canonical_name"] == "acme/ticket_read"
    assert descriptor.origin["package"] == "acme_tickets"
    assert descriptor.interface["output_schema"] == %{"type" => "object"}
    assert descriptor.effects["resource_types"] == ["ticket"]
    assert descriptor.policy["approval"] == "never"
    assert Descriptor.timeout_ms(descriptor, 10_000) == 2_000
    assert Descriptor.output_limit(descriptor, 10_000) == 4_000
    assert Descriptor.concurrency(descriptor) == {:resource, "tickets"}
  end

  # The direction of doubt is the whole rule: a lost result is called unknown
  # wherever believing "it failed" could have a model repeat a side effect.
  test "a lost result is unknown for external, receipted and MCP tools, and not for the rest" do
    refute Descriptor.receipt?(Descriptor.new(TicketReader))
    assert Descriptor.receipt?(Descriptor.new(TicketReader, effects: %{"class" => "external"}))
    assert Descriptor.receipt?(Descriptor.new(TicketReader, effects: %{"receipt" => true}))

    refute Descriptor.receipt?(
             Descriptor.new(TicketReader, effects: %{"class" => "external", "idempotent" => true})
           )

    refute Descriptor.receipt?(
             Descriptor.new(TicketReader, effects: %{"class" => "external", "receipt" => false})
           )

    remote = %Lemieux.MCP.RemoteTool{
      server: "tickets",
      name: "create",
      description: "Creates a ticket.",
      schema: %{"type" => "object"}
    }

    assert Descriptor.new(remote).origin["type"] == "mcp"
    assert Descriptor.receipt?(Descriptor.new(remote))
    refute Descriptor.receipt?(Descriptor.new(remote, effects: %{"idempotent" => true}))
  end

  test "a descriptor remains dispatch-compatible with the legacy behaviour" do
    descriptor = Descriptor.new(TicketReader, identity: %{namespace: "acme"})

    assert {:ok, "ticket 42"} = Tool.invoke(descriptor, %{"id" => "42"}, %{})
    assert Tool.validate_all([descriptor]) == :ok
  end

  test "a host can narrow an existing descriptor without wrapping its executor twice" do
    original = Descriptor.new(TicketReader, identity: %{namespace: "acme"})
    narrowed = Descriptor.new(original, policy: %{approval: "always"})

    assert narrowed.executor == TicketReader
    assert narrowed.identity["canonical_name"] == "acme/ticket_read"
    assert narrowed.policy["approval"] == "always"
    assert {:ok, "ticket 7"} = Tool.invoke(narrowed, %{"id" => "7"}, %{})
  end

  describe "deadlines" do
    test "a tool that declares none runs under the host's maximum, whatever it is" do
      descriptor = Tool.descriptor(TicketReader)

      refute Map.has_key?(descriptor.runtime, "timeout_ms")
      assert Descriptor.timeout_ms(descriptor, :timer.hours(1)) == :timer.hours(1)
      assert Descriptor.timeout_ms(descriptor, 5_000) == 5_000
    end

    # A server's tool declares no deadline of its own, so the session's
    # maximum is its budget: the MCP client's progress-extended call budget is
    # reachable only if nothing here cuts the call off first.
    test "a remote MCP tool runs under the host's maximum too" do
      remote = %Lemieux.MCP.RemoteTool{
        name: "slow_report",
        server: "reports",
        description: "Builds a report.",
        schema: %{"type" => "object"}
      }

      descriptor = Tool.descriptor(remote)

      refute Map.has_key?(descriptor.runtime, "timeout_ms")
      assert Descriptor.timeout_ms(descriptor, :timer.minutes(10)) == :timer.minutes(10)
      assert Descriptor.timeout_ms(descriptor, :timer.hours(1)) == :timer.hours(1)
    end

    test "a declared deadline still applies under the host's maximum" do
      descriptor = Descriptor.new(TicketReader, runtime: %{"timeout_ms" => 2_000})

      assert Descriptor.timeout_ms(descriptor, :timer.hours(1)) == 2_000
      assert Descriptor.timeout_ms(descriptor, 500) == 500
    end

    test "an invalid declared deadline is refused" do
      assert_raise ArgumentError, fn ->
        Descriptor.new(TicketReader, runtime: %{"timeout_ms" => 0})
      end
    end
  end

  describe "approval" do
    test "reads the declared policy, defaulting to the host's" do
      assert Descriptor.approval(Tool.descriptor(TicketReader)) == :policy

      assert Descriptor.approval(Descriptor.new(TicketReader, policy: %{approval: "never"})) ==
               :never

      assert Descriptor.approval(Descriptor.new(TicketReader, policy: %{approval: "always"})) ==
               :always

      assert Tool.approval(Lemieux.Tools.Read) == :never
      assert Tool.approval(Lemieux.Tools.Bash) == :policy
    end
  end
end
