defmodule Lemieux.ToolTest do
  use ExUnit.Case, async: true

  alias Lemieux.Tool
  alias Lemieux.Tool.Descriptor
  alias Lemieux.Tool.Result

  defmodule First do
    @moduledoc false
    @behaviour Tool

    @impl Tool
    def name, do: "same"
    @impl Tool
    def description, do: "The first definition."
    @impl Tool
    def schema, do: %{"type" => "object"}
    @impl Tool
    def run(_args, _context), do: {:ok, "first"}
  end

  defmodule Second do
    @moduledoc false
    @behaviour Tool

    @impl Tool
    def name, do: "same"
    @impl Tool
    def description, do: "The second definition."
    @impl Tool
    def schema, do: %{"type" => "object"}
    @impl Tool
    def run(_args, _context), do: {:ok, "second"}
  end

  defmodule InvalidSchema do
    @moduledoc false
    @behaviour Tool

    @impl Tool
    def name, do: "invalid"
    @impl Tool
    def description, do: "Has a provider-invalid schema."
    @impl Tool
    def schema, do: %{type: :object}
    @impl Tool
    def run(_args, _context), do: {:ok, "never called"}
  end

  defmodule Configured do
    @moduledoc false
    @behaviour Lemieux.Tool.Configured

    defstruct [:label]

    @impl Lemieux.Tool.Configured
    def name(%__MODULE__{}), do: "configured"
    @impl Lemieux.Tool.Configured
    def description(%__MODULE__{label: label}), do: "Configured with #{label}."
    @impl Lemieux.Tool.Configured
    def schema(%__MODULE__{}), do: %{"type" => "object"}
    @impl Lemieux.Tool.Configured
    def run(%__MODULE__{label: label}, _args, _context), do: {:ok, label}
  end

  defmodule HalfConfigured do
    @moduledoc false
    defstruct [:label]

    def name(%__MODULE__{}), do: "half"
    def description(%__MODULE__{}), do: "Has a name and a description, nothing to run."
  end

  # The module documentation's example is the first tool most hosts copy, so
  # it is compiled from the documentation itself and held to the contract.
  test "the documented example tool validates and answers both ways" do
    {:docs_v1, _anno, _language, _format, %{"en" => moduledoc}, _meta, _docs} =
      Code.fetch_docs(Tool)

    [example] = Regex.run(~r/^    defmodule MyApp\.Tools\.Weekday do\n.*?^    end\n/ms, moduledoc)

    [{module, _bytecode} | _rest] =
      example |> String.replace(~r/^    /m, "") |> Code.compile_string()

    assert Tool.validate_all([module]) == :ok
    assert Tool.read_only?(module)
    assert module.run(%{"date" => "2026-10-03"}, %{}) == {:ok, "Saturday"}

    assert {:error, "next Tuesday is not a date" <> _rest} =
             module.run(%{"date" => "next Tuesday"}, %{})

    assert {:error, _reason} = module.run(%{}, %{})
  end

  test "accepts a valid catalog" do
    assert Tool.validate_all([Lemieux.Tools.Read, Lemieux.Tools.Write]) == :ok
  end

  test "rejects duplicate names before dispatch can become ambiguous" do
    assert Tool.validate_all([First, Second]) == {:error, {:duplicate_tool_name, "same"}}
  end

  test "rejects schemas that are not JSON Schema objects" do
    assert Tool.validate_all([InvalidSchema]) == {:error, {:invalid_tool, 0, :invalid_metadata}}
  end

  test "rejects modules missing the tool callbacks" do
    assert Tool.validate_all([String]) ==
             {:error, {:invalid_tool, 0, {:missing_callbacks, String}}}
  end

  describe "the configured plane" do
    test "a struct whose module implements Lemieux.Tool.Configured is a tool" do
      tool = %Configured{label: "one"}

      assert Tool.validate_all([tool, Lemieux.Tools.Read]) == :ok
      assert Tool.name(tool) == "configured"
      assert Tool.description(tool) == "Configured with one."
      assert Tool.invoke(tool, %{}, %{}) == {:ok, "one"}
      refute Tool.parallel_safe?(tool)
      refute Tool.read_only?(tool)
    end

    test "a struct missing callbacks is told which ones and where the contract lives" do
      assert Tool.validate_all([%HalfConfigured{}]) ==
               {:error,
                {:invalid_tool, 0,
                 {:missing_callbacks, HalfConfigured,
                  %{behaviour: Lemieux.Tool.Configured, missing: [schema: 1, run: 3]}}}}
    end

    test "a struct that was never a tool is missing all four" do
      assert {:error, {:invalid_tool, 0, {:missing_callbacks, MapSet, %{missing: missing}}}} =
               Tool.validate_all([MapSet.new()])

      assert missing == [name: 1, description: 1, schema: 1, run: 3]
    end

    test "the bundled configured tools declare the behaviour" do
      for module <- [
            Lemieux.Tools.Bash,
            Lemieux.Tools.WebSearch,
            Lemieux.Tools.WebFetch,
            Lemieux.Tool.Override,
            Lemieux.Extensions.Workspace.SkillTool,
            Lemieux.Subagent.Delegate
          ] do
        behaviours =
          module.__info__(:attributes) |> Keyword.get_values(:behaviour) |> List.flatten()

        assert Lemieux.Tool.Configured in behaviours,
               "#{inspect(module)} does not declare Lemieux.Tool.Configured"
      end
    end
  end

  describe "decorate/2" do
    alias Lemieux.Tool.Override
    alias Lemieux.Tools.{Bash, Read, Write}

    test "wraps only the named tools, in place, and hands each wrapper the tool it names" do
      owner = self()

      wrappers = %{
        "write" => fn tool ->
          send(owner, {:wrapped, tool})
          Override.new!(tool, description: "Write inside the repo.")
        end
      }

      assert [Read, %Override{tool: Write} = write, Bash] =
               Tool.decorate([Read, Write, Bash], wrappers)

      assert Tool.description(write) == "Write inside the repo."
      assert_received {:wrapped, Write}
    end

    test "accepts a list of pairs and leaves an empty catalog alone" do
      assert [%Override{tool: Read}] =
               Tool.decorate([Read], [{"read", &Override.new!(&1, description: "R")}])

      assert Tool.decorate([], %{}) == []
      assert Tool.decorate([Read, Bash], %{}) == [Read, Bash]
    end

    test "a wrapper may replace the tool with any other tool shape" do
      assert [Write] = Tool.decorate([Read], %{"read" => fn Read -> Write end})

      assert [%Lemieux.Tool.Descriptor{executor: Read}] =
               Tool.decorate([Read], %{"read" => &Descriptor.new/1})
    end

    test "a name that matches no tool raises rather than silently wrapping nothing" do
      error =
        assert_raise ArgumentError, fn ->
          Tool.decorate([Read, Bash], %{"wrte" => & &1})
        end

      assert error.message =~ ~s("wrte")
      assert error.message =~ "read, bash"
    end

    test "a name given twice raises rather than wrapping twice" do
      wrapper = &Override.new!(&1, description: "twice")

      assert_raise ArgumentError, ~r/"read".*twice|twice.*"read"/, fn ->
        Tool.decorate([Read], [{"read", wrapper}, {"read", wrapper}])
      end
    end

    test "a name that two tools share raises rather than applying the wrapper to both" do
      assert_raise ArgumentError, ~r/two tools named "same"/, fn ->
        Tool.decorate([First, Second], %{"same" => & &1})
      end
    end

    test "a wrapper that returns something other than a tool raises at the composition point" do
      assert_raise ArgumentError, ~r/"read".*returned nil/, fn ->
        Tool.decorate([Read], %{"read" => fn _tool -> nil end})
      end

      assert_raise ArgumentError, ~r/not a function of one argument/, fn ->
        Tool.decorate([Read], %{"read" => :not_a_function})
      end
    end
  end

  describe "collect_result/3, at the seam every tool result crosses" do
    # `bash` states "no output" and the MCP client substitutes "(the tool
    # returned no output)", because both of their authors knew a silent result
    # reads as a completed one. Nothing enforced that for a tool an embedder
    # wrote, and the empty string is not a result: it is stored in the
    # transcript, re-sent on every later request, and reaches the provider as
    # empty content.
    test "a tool that returns nothing has that said for it" do
      for output <- ["", [], ["", ""], Result.new("")] do
        assert {:ok, result} = Tool.collect_result({:ok, output}, fn _ -> :ok end, 30_000)
        assert result.model_text =~ "no output"
      end
    end

    test "a stream that yields nothing has that said for it" do
      assert {:ok, result} = Tool.collect_result({:stream, []}, fn _ -> :ok end, 30_000)
      assert result.model_text =~ "no output"
    end

    test "a terminal success retains structured evidence and closes the stream" do
      owner = self()
      terminal = Result.new("done", structured_content: %{"exit_status" => 3})

      stream =
        Stream.resource(
          fn -> ["started\n", {:ok, terminal}, "unreachable"] end,
          fn [item | rest] -> {[item], rest} end,
          fn _ -> send(owner, :closed) end
        )

      assert {:ok, result} =
               Tool.collect_result({:stream, stream}, &send(owner, {:chunk, &1}), 100)

      assert result.model_text == "started\ndone"
      assert result.structured_content == %{"exit_status" => 3}
      assert_receive {:chunk, "started\n"}
      assert_receive {:chunk, "done"}
      assert_receive :closed
      refute_receive {:chunk, "unreachable"}
    end

    test "an empty terminal success preserves prior output and bounds structured evidence" do
      terminal = Result.new("", structured_content: %{"log" => String.duplicate("x", 1_000)})

      assert {:ok, result} =
               Tool.collect_result({:stream, ["hello", {:ok, terminal}]}, fn _ -> :ok end, 200)

      assert result.model_text =~ "hello"
      assert result.model_text =~ "audit budget"
      assert result.structured_content["truncated"] == true
      refute result.model_text =~ "no output"
    end

    # Whitespace is not output either, and a provider that rejects an empty
    # text block rejects a blank one for the same reason.
    test "whitespace alone does not count as having said something" do
      assert {:ok, result} = Tool.collect_result({:ok, "  \n\t "}, fn _ -> :ok end, 30_000)
      assert result.model_text =~ "no output"
    end

    test "a failure with nothing to say is still a failure, not an absence" do
      assert {:error, result} = Tool.collect_result({:error, ""}, fn _ -> :ok end, 30_000)
      refute result.model_text == ""
      refute result.model_text =~ "no output"
    end

    test "output that says something is left exactly as it is" do
      assert {:ok, result} = Tool.collect_result({:ok, "hello"}, fn _ -> :ok end, 30_000)
      assert result.model_text == "hello"
    end
  end

  describe "one answer about effects and concurrency" do
    defmodule SaysReadDeclaresWrite do
      @moduledoc false
      @behaviour Tool

      @impl Tool
      def name, do: "contradictory"
      @impl Tool
      def description, do: "Says one thing and declares another."
      @impl Tool
      def schema, do: %{"type" => "object"}
      @impl Tool
      def run(_args, _context), do: {:ok, "ran"}
      @impl Tool
      def read_only?, do: true
      @impl Tool
      def parallel_safe?, do: true
      @impl Tool
      def metadata,
        do: %{effects: %{class: :write}, runtime: %{concurrency: %{class: "exclusive"}}}
    end

    defmodule DeclaresReadOnly do
      @moduledoc false
      @behaviour Tool

      @impl Tool
      def name, do: "declared"
      @impl Tool
      def description, do: "Declares its effects and nothing else."
      @impl Tool
      def schema, do: %{"type" => "object"}
      @impl Tool
      def run(_args, _context), do: {:ok, "ran"}
      @impl Tool
      def metadata,
        do: %{
          "effects" => %{"class" => "read"},
          "runtime" => %{"concurrency" => %{"class" => "parallel"}}
        }
    end

    test "declared metadata wins over the callbacks, and matches the descriptor" do
      refute Tool.read_only?(SaysReadDeclaresWrite)
      refute Tool.parallel_safe?(SaysReadDeclaresWrite)
      refute Tool.read_only?(Tool.descriptor(SaysReadDeclaresWrite))
      refute Tool.parallel_safe?(Tool.descriptor(SaysReadDeclaresWrite))
    end

    test "metadata alone is enough to be read-only and parallel" do
      assert Tool.read_only?(DeclaresReadOnly)
      assert Tool.parallel_safe?(DeclaresReadOnly)
      assert Tool.read_only?(Tool.descriptor(DeclaresReadOnly))
    end

    defmodule CallbacksOnly do
      @moduledoc false
      @behaviour Tool

      @impl Tool
      def name, do: "callbacks_only"
      @impl Tool
      def description, do: "Answers through its callbacks alone."
      @impl Tool
      def schema, do: %{"type" => "object"}
      @impl Tool
      def run(_args, _context), do: {:ok, "ran"}
      @impl Tool
      def read_only?, do: true
      @impl Tool
      def parallel_safe?, do: true
    end

    test "the callbacks still answer when the metadata is silent" do
      assert Tool.read_only?(CallbacksOnly)
      assert Tool.parallel_safe?(CallbacksOnly)
      assert Tool.read_only?(Tool.descriptor(CallbacksOnly))
    end
  end
end
