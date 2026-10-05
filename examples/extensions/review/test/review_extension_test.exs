defmodule ReviewExtensionTest do
  use ExUnit.Case, async: true

  alias Lemieux.Agent
  alias Lemieux.Providers.Scripted

  @moduletag :tmp_dir

  # Three lines, so a finding on line 3 names a real place and line 4 does not.
  @source """
  defmodule Division do
    def ratio(a, b), do: a / b
  end
  """

  setup %{tmp_dir: tmp_dir} do
    cwd = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(cwd)
    %{cwd: cwd, sessions: Path.join(tmp_dir, "sessions")}
  end

  defp review(context, answer) do
    provider = Scripted.new([Scripted.complete(answer)])

    opts = [
      provider: provider,
      model: "test:model",
      supervisor: :"review_example_#{System.unique_integer([:positive])}",
      sessions_dir: context.sessions,
      session_options: [max_turns: 1]
    ]

    input = %{prompt: "Find defects.", cwd: context.cwd, timeout_ms: 30_000}
    Agent.run(ReviewExtension, input, opts)
  end

  defp findings(list), do: JSON.encode!(%{"findings" => list})

  test "a finding at a line the file has is accepted, and the reviewed files are named",
       context do
    File.write!(Path.join(context.cwd, "division.ex"), @source)

    answer = findings([%{"path" => "division.ex", "line" => 2, "message" => "b may be zero"}])

    assert {:ok, observation} = review(context, answer)
    assert observation["reviewed_files"] == ["division.ex"]
  end

  test "a finding past the file's last line is refused", context do
    File.write!(Path.join(context.cwd, "division.ex"), @source)

    answer = findings([%{"path" => "division.ex", "line" => 40, "message" => "made up"}])

    assert {:error, :invalid_review, _observation} = review(context, answer)
  end

  test "a finding in a file that was not reviewed is refused", context do
    File.write!(Path.join(context.cwd, "division.ex"), @source)

    answer = findings([%{"path" => "other.ex", "line" => 1, "message" => "elsewhere"}])

    assert {:error, :invalid_review, _observation} = review(context, answer)
  end

  test "an answer that is not the findings contract is refused", context do
    File.write!(Path.join(context.cwd, "division.ex"), @source)

    assert {:error, :invalid_review, _observation} = review(context, "looks fine to me")
  end

  test "a directory with no top-level Elixir files is refused before any model call", context do
    assert {:error, :expected_one_to_eight_elixir_files} = review(context, findings([]))
  end

  test "only the explicit scripted profile is supported" do
    assert {:error, :unsupported_review_profile} =
             ReviewExtension.configure(%{"execution" => "live"})
  end
end
