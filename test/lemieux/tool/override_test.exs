defmodule Lemieux.Tool.OverrideTest do
  use ExUnit.Case, async: true

  alias Lemieux.Harness.Snapshot
  alias Lemieux.Providers.Scripted
  alias Lemieux.Request
  alias Lemieux.Store.JSONL
  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tool.Override
  alias Lemieux.Tools.Read

  @moduletag :tmp_dir

  @description "Open one file. Reach for this before `bash cat`; it numbers lines."

  defmodule Echo do
    @moduledoc false
    @behaviour Tool

    @impl Tool
    def name, do: "echo"
    @impl Tool
    def description, do: "Returns its arguments."
    @impl Tool
    def schema, do: %{"type" => "object"}
    @impl Tool
    def run(args, _context) do
      if owner = args["owner"], do: send(owner, {:echo_ran, args})
      {:ok, args |> Map.delete("owner") |> Enum.sort() |> inspect()}
    end
  end

  defmodule Streamer do
    @moduledoc false
    @behaviour Tool

    @impl Tool
    def name, do: "streamer"
    @impl Tool
    def description, do: "Streams two chunks."
    @impl Tool
    def schema, do: %{"type" => "object"}
    @impl Tool
    def run(%{"owner" => owner}, _context) do
      stream =
        Stream.resource(
          fn ->
            send(owner, :stream_started)
            ["a", "b"]
          end,
          fn
            [] -> {:halt, []}
            [chunk | rest] -> {[chunk], rest}
          end,
          fn _ -> send(owner, :stream_closed) end
        )

      {:stream, stream}
    end
  end

  @doc false
  def pass(args, _context), do: {:ok, args}

  describe "new/2" do
    test "overrides the description and defers everything else to the wrapped tool" do
      assert {:ok, override} = Override.new(Read, description: @description)

      assert Tool.name(override) == "read"
      assert Tool.description(override) == @description
      assert Tool.schema(override) == Read.schema()
      assert Tool.parallel_safe?(override) == Tool.parallel_safe?(Read)
      assert Tool.read_only?(override) == Tool.read_only?(Read)
      assert Tool.read_only?(override)
    end

    test "overrides the name and schema when asked" do
      schema = %{
        "type" => "object",
        "properties" => %{"path" => %{"type" => "string"}},
        "required" => ["path"],
        "additionalProperties" => false
      }

      assert {:ok, override} = Override.new(Read, name: "peek", schema: schema)

      assert Tool.name(override) == "peek"
      assert Tool.description(override) == Read.description()
      assert Tool.schema(override) == schema
    end

    test "follows a wrapped tool that is not parallel safe or read only" do
      assert {:ok, override} = Override.new(Lemieux.Tools.Bash, description: @description)

      refute Tool.parallel_safe?(override)
      refute Tool.read_only?(override)
    end

    test "rejects construction that would reach the model malformed or silently changed" do
      assert {:error, :empty_description} = Override.new(Read, description: "")
      assert {:error, :empty_description} = Override.new(Read, description: "  \n")
      assert {:error, :invalid_description} = Override.new(Read, description: :atom)
      assert {:error, :empty_name} = Override.new(Read, name: "")
      assert {:error, :invalid_schema} = Override.new(Read, schema: %{"type" => "string"})

      assert {:error, :invalid_schema} =
               Override.new(Read, schema: %{"type" => "object", "x" => self()})

      assert {:error, :nothing_overridden} = Override.new(Read, [])
      assert {:error, {:unknown_option, :desc}} = Override.new(Read, desc: @description)

      assert {:error, {:invalid_tool, {:missing_callbacks, Lemieux.Tool.OverrideTest.Missing}}} =
               Override.new(Lemieux.Tool.OverrideTest.Missing, description: @description)

      assert_raise ArgumentError, ~r/empty_description/, fn ->
        Override.new!(Read, description: "")
      end

      assert %Override{} = Override.new!(Read, description: @description)
    end
  end

  describe "descriptor" do
    test "keeps the wrapped tool's identity and effects, records the override, and changes the digest" do
      {:ok, override} = Override.new(Read, description: @description)

      descriptor = Tool.descriptor(override)
      plain = Tool.descriptor(Read)

      assert descriptor.digest != plain.digest
      assert descriptor.interface["description"] == @description
      assert descriptor.interface["input_schema"] == plain.interface["input_schema"]
      assert descriptor.identity["canonical_name"] == plain.identity["canonical_name"]

      assert descriptor.identity["implementation_digest"] ==
               plain.identity["implementation_digest"]

      assert descriptor.origin["overrides"] == %{"tool" => "read", "fields" => ["description"]}
      assert descriptor.origin["module"] == plain.origin["module"]
      assert descriptor.effects == plain.effects
      assert descriptor.policy == plain.policy
      assert descriptor.runtime == plain.runtime

      assert Tool.metadata(override)["overrides"] ==
               %{"tool" => "read", "fields" => ["description"]}

      assert :ok = Descriptor.validate(descriptor)
    end

    test "lists every overridden field in a stable order" do
      {:ok, override} =
        Override.new(Read,
          schema: %{"type" => "object", "properties" => %{}},
          name: "peek",
          description: @description
        )

      assert Tool.descriptor(override).origin["overrides"] ==
               %{"tool" => "read", "fields" => ["description", "name", "schema"]}
    end

    test "two overrides of one tool with different text are distinguishable in evidence" do
      {:ok, one} = Override.new(Read, description: "one")
      {:ok, two} = Override.new(Read, description: "two")

      assert Tool.descriptor(one).digest != Tool.descriptor(two).digest

      first = Snapshot.build(%Request{model: "test:model", tools: [one]})
      second = Snapshot.build(%Request{model: "test:model", tools: [two]})
      plain = Snapshot.build(%Request{model: "test:model", tools: [Read]})

      assert first.tools["sha256"] != second.tools["sha256"]
      assert first.tools["sha256"] != plain.tools["sha256"]
      assert [%{"description" => "one"}] = first.tools["descriptors"]
    end
  end

  describe "catalog" do
    test "validate_all and fetch treat the override as the tool it names" do
      {:ok, override} = Override.new(Read, description: @description)

      assert :ok = Tool.validate_all([override, Lemieux.Tools.Bash])
      assert {:error, {:duplicate_tool_name, "read"}} = Tool.validate_all([override, Read])
      assert {:ok, ^override} = Tool.fetch([Lemieux.Tools.Bash, override], "read")

      {:ok, renamed} = Override.new(Read, name: "peek", description: @description)

      assert :ok = Tool.validate_all([renamed, Read])
      assert {:ok, ^renamed} = Tool.fetch([Read, renamed], "peek")
      assert :error = Tool.fetch([renamed], "read")
    end
  end

  describe "wrapping execution" do
    test "before rewrites the arguments the wrapped tool receives" do
      {:ok, override} =
        Override.new(Echo, before: fn args, _context -> {:ok, Map.put(args, "extra", 1)} end)

      assert Tool.invoke(override, %{"path" => "x"}, %{}) ==
               {:ok, inspect([{"extra", 1}, {"path", "x"}])}
    end

    test "before sees the context and can refuse; the wrapped tool then does not run" do
      {:ok, override} =
        Override.new(Echo,
          before: fn _args, %{session_id: id} -> {:error, "refused for #{id}"} end
        )

      assert Tool.invoke(override, %{"owner" => self()}, %{session_id: "s9"}) ==
               {:error, "refused for s9"}

      refute_received {:echo_ran, _args}
    end

    test "before returning something other than ok or error is a wrapper bug, said plainly" do
      {:ok, override} = Override.new(Echo, before: fn args, _context -> args end)

      assert_raise ArgumentError, ~r/before.*returned %\{\}/, fn ->
        Tool.invoke(override, %{}, %{})
      end
    end

    test "after receives the inner return, the effective arguments and the context" do
      owner = self()

      {:ok, override} =
        Override.new(Echo,
          before: fn args, _context -> {:ok, Map.put(args, "n", 2)} end,
          after: fn inner, args, context ->
            send(owner, {:after, inner, args, context})
            {:ok, "decorated"}
          end
        )

      assert Tool.invoke(override, %{"n" => 1}, %{call_id: "c1"}) == {:ok, "decorated"}

      assert_received {:after, {:ok, inner_text}, %{"n" => 2}, %{call_id: "c1"}}
      assert inner_text == inspect([{"n", 2}])
    end

    test "after receives a stream verbatim and may wrap the enumerable without collecting it" do
      owner = self()

      {:ok, override} =
        Override.new(Streamer,
          after: fn {:stream, stream}, _args, _context ->
            {:stream, Stream.map(stream, &String.upcase/1)}
          end
        )

      assert {:stream, wrapped} = Tool.invoke(override, %{"owner" => owner}, %{})
      # Nothing has been pulled: wrapping the enumerable did not force it.
      refute_received :stream_started

      assert {:ok, "AB"} = Tool.collect({:stream, wrapped})
      assert_received :stream_started
      assert_received :stream_closed
    end

    test "wrapping does not change what the model reads or how the tool is scheduled" do
      {:ok, override} = Override.new(Read, after: fn inner, _args, _context -> inner end)

      assert Tool.name(override) == "read"
      assert Tool.description(override) == Read.description()
      assert Tool.schema(override) == Read.schema()
      assert Tool.parallel_safe?(override) == Tool.parallel_safe?(Read)
      assert Tool.read_only?(override) == Tool.read_only?(Read)
    end

    test "a text-only override still delegates run untouched" do
      {:ok, override} = Override.new(Echo, description: "text only")
      assert Tool.invoke(override, %{"k" => "v"}, %{}) == {:ok, inspect([{"k", "v"}])}
    end

    test "rejects wrappers of the wrong shape and a digest with nothing to digest" do
      assert {:error, :invalid_before} = Override.new(Read, before: fn _args -> :ok end)
      assert {:error, :invalid_before} = Override.new(Read, before: :not_a_function)
      assert {:error, :invalid_after} = Override.new(Read, after: fn _inner, _args -> :ok end)
      assert {:error, :invalid_digest} = Override.new(Read, before: &pass/2, digest: "")
      assert {:error, :invalid_digest} = Override.new(Read, before: &pass/2, digest: :atom)
      assert {:error, :digest_without_wrapper} = Override.new(Read, digest: "audit-v1")

      assert {:error, :digest_without_wrapper} =
               Override.new(Read, description: @description, digest: "audit-v1")

      assert {:error, :nothing_overridden} = Override.new(Read, before: nil, after: nil)
    end
  end

  describe "the identity of a wrapping override" do
    test "changes the implementation digest and records run among the overridden fields" do
      {:ok, override} = Override.new(Read, before: &pass/2)

      descriptor = Tool.descriptor(override)
      plain = Tool.descriptor(Read)

      assert descriptor.identity["implementation_digest"] !=
               plain.identity["implementation_digest"]

      assert descriptor.digest != plain.digest
      assert descriptor.identity["canonical_name"] == plain.identity["canonical_name"]
      assert descriptor.origin["overrides"] == %{"tool" => "read", "fields" => ["run"]}
      assert descriptor.interface == plain.interface
      assert descriptor.effects == plain.effects
      assert :ok = Descriptor.validate(descriptor)
    end

    test "a described and decorated override lists both, in a stable order" do
      {:ok, override} =
        Override.new(Read,
          after: fn inner, _args, _context -> inner end,
          description: @description
        )

      assert Tool.descriptor(override).origin["overrides"] ==
               %{"tool" => "read", "fields" => ["description", "run"]}
    end

    test "the same wrapper yields the same digest; a different one a different digest" do
      {:ok, one} = Override.new(Read, before: &pass/2)
      {:ok, two} = Override.new(Read, before: &pass/2)
      {:ok, three} = Override.new(Read, before: fn args, _context -> {:ok, args} end)
      {:ok, four} = Override.new(Read, after: fn inner, _args, _context -> inner end)

      digest = &Tool.descriptor(&1).identity["implementation_digest"]

      assert digest.(one) == digest.(two)
      assert digest.(one) != digest.(three)
      assert digest.(one) != digest.(four)
      assert digest.(three) != digest.(four)
    end

    test "an explicit digest names the wrapper independently of the closure that carries it" do
      {:ok, one} =
        Override.new(Read, before: fn args, _context -> {:ok, args} end, digest: "audit-v1")

      {:ok, same} = Override.new(Read, before: &pass/2, digest: "audit-v1")
      {:ok, other} = Override.new(Read, before: &pass/2, digest: "audit-v2")
      {:ok, plain_read} = Override.new(Lemieux.Tools.Write, before: &pass/2, digest: "audit-v1")

      digest = &Tool.descriptor(&1).identity["implementation_digest"]

      assert digest.(one) == digest.(same)
      assert digest.(one) != digest.(other)
      # The wrapper's digest is folded into the wrapped tool's, not substituted for it.
      assert digest.(one) != digest.(plain_read)
      assert digest.(one) != Tool.descriptor(Read).identity["implementation_digest"]
    end

    test "text on top of a wrapper does not move the implementation digest" do
      {:ok, bare} = Override.new(Read, before: &pass/2)
      {:ok, described} = Override.new(Read, before: &pass/2, description: @description)

      assert Tool.descriptor(bare).identity["implementation_digest"] ==
               Tool.descriptor(described).identity["implementation_digest"]

      assert Tool.descriptor(bare).digest != Tool.descriptor(described).digest
    end
  end

  describe "in a session" do
    setup %{tmp_dir: tmp_dir} do
      runtime = :"override_test_#{System.unique_integer([:positive])}"
      start_supervised!({Lemieux.Supervisor, name: runtime})
      File.write!(Path.join(tmp_dir, "notes.txt"), "hello from the file\n")
      %{runtime: runtime}
    end

    test "the model is shown the override and the wrapped tool does the work", context do
      {:ok, override} = Override.new(Read, description: @description)

      provider =
        Scripted.new([
          Scripted.tool_call("t1", "read", %{"path" => "notes.txt"}),
          Scripted.complete("done")
        ])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: provider,
          store: JSONL.new(Path.join(context.tmp_dir, "sessions")),
          model: "test:model",
          cwd: context.tmp_dir,
          tools: [override]
        )

      assert {:ok, result} = Lemieux.Testing.prompt(session, "read the notes")
      assert result.stop_reason == :stop

      request = Enum.find(result.entries, &(&1.type == :request))

      assert [%{"name" => "read", "description" => @description}] =
               request.payload["tools"]

      tool_result = Enum.find(result.entries, &(&1.type == :tool_result))
      assert tool_result.payload["name"] == "read"
      assert tool_result.payload["error"] == false
      assert tool_result.payload["output"] =~ "hello from the file"

      assert [%Request{tools: [%Override{tool: Read}]} | _rest] = Scripted.requests(provider)
    end

    test "a wrapping override decorates the result the model reads", context do
      {:ok, override} =
        Override.new(Read,
          after: fn
            {:ok, output}, %{"path" => path}, _context -> {:ok, [output, "\n[audited #{path}]"]}
            other, _args, _context -> other
          end
        )

      provider =
        Scripted.new([
          Scripted.tool_call("t1", "read", %{"path" => "notes.txt"}),
          Scripted.complete("done")
        ])

      {:ok, session} =
        Lemieux.start_session(
          supervisor: context.runtime,
          provider: provider,
          store: JSONL.new(Path.join(context.tmp_dir, "sessions")),
          model: "test:model",
          cwd: context.tmp_dir,
          tools: [override]
        )

      assert {:ok, result} = Lemieux.Testing.prompt(session, "read the notes")

      tool_result = Enum.find(result.entries, &(&1.type == :tool_result))
      assert tool_result.payload["error"] == false
      assert tool_result.payload["output"] =~ "hello from the file"
      assert tool_result.payload["output"] =~ "[audited notes.txt]"

      assert tool_result.payload["tool_identity"]["implementation_digest"] !=
               Tool.descriptor(Read).identity["implementation_digest"]
    end
  end
end
