defmodule Lemieux.Extensions.Workspace.SkillTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Workspace.Skill

  @moduletag :tmp_dir

  test "reads YAML frontmatter including a block-scalar description", %{tmp_dir: tmp_dir} do
    path =
      write(
        tmp_dir,
        "review/SKILL.md",
        """
        ---
        name: review
        description: >-
          Review a change carefully and use this skill
          when the user asks for code review.
        ---

        SECRET BODY THAT IS LOADED LATER
        """
      )

    assert {:ok, skill} = Skill.read(path)
    assert skill.name == "review"
    assert skill.description =~ "Review a change carefully"
    assert skill.description =~ "when the user asks"
    assert skill.path == Path.expand(path)
  end

  test "discovery keeps valid neighbors and reports malformed skills", %{tmp_dir: tmp_dir} do
    write(
      tmp_dir,
      "good/SKILL.md",
      "---\nname: good\ndescription: Useful for good work.\n---\nbody"
    )

    write(tmp_dir, "bad/SKILL.md", "there is no frontmatter")

    assert {[skill], [diagnostic]} = Skill.discover([tmp_dir])
    assert skill.name == "good"
    assert diagnostic =~ "bad/SKILL.md needs YAML frontmatter"
  end

  test "plugin namespaces make otherwise identical skill names distinct", %{tmp_dir: tmp_dir} do
    write(
      tmp_dir,
      "review/SKILL.md",
      "---\nname: review\ndescription: Review code.\n---\nbody"
    )

    assert {[skill], []} = Skill.discover([tmp_dir], namespace: "quality")
    assert Skill.qualified_name(skill) == "quality:review"
  end

  test "invocation controls visibility and expands positional arguments", %{tmp_dir: tmp_dir} do
    path =
      write(
        tmp_dir,
        "release/SKILL.md",
        """
        ---
        name: release
        description: Release one application.
        argument-hint: "[application] [environment]"
        disable-model-invocation: true
        ---
        Release $0 to $ARGUMENTS[1]. Full input: $ARGUMENTS
        """
      )

    assert {:ok, skill} = Skill.read(path)
    refute skill.model_invocable?
    assert skill.user_invocable?
    assert skill.argument_hint == "[application] [environment]"
    assert {:ok, rendered} = Skill.render(skill, "web production")
    assert rendered =~ "Release web to production. Full input: web production"
    refute rendered =~ "disable-model-invocation"
  end

  test "legacy command markdown uses its filename and first paragraph", %{tmp_dir: tmp_dir} do
    path =
      write(tmp_dir, "commands/check-release.md", "Check the release carefully.\n\nDo it now.")

    assert {:ok, command} = Skill.read_command(path)
    assert command.name == "check-release"
    assert command.description == "Check the release carefully."
    assert command.model_invocable?
    assert command.user_invocable?
  end

  test "legacy commands honor modern invocation controls", %{tmp_dir: tmp_dir} do
    path =
      write(
        tmp_dir,
        "commands/deploy.md",
        "---\ndescription: Deploy safely.\ndisable-model-invocation: true\nuser-invocable: false\n---\nDeploy"
      )

    assert {:ok, command} = Skill.read_command(path)
    refute command.model_invocable?
    refute command.user_invocable?
  end

  test "discovers legacy command roots with later roots winning", %{tmp_dir: tmp_dir} do
    first = Path.join(tmp_dir, "first")
    second = Path.join(tmp_dir, "second")
    write(first, "review.md", "Review the first way.")
    write(second, "review.md", "Review the second way.")

    assert {[command], []} = Skill.discover_commands([first, second])
    assert command.description == "Review the second way."
  end

  test "diagnoses unsupported executable and isolated skill semantics", %{tmp_dir: tmp_dir} do
    path =
      write(
        tmp_dir,
        "review/SKILL.md",
        """
        ---
        name: review
        description: Review a change.
        allowed-tools: Bash(git diff:*)
        context: fork
        model: fast
        ---
        Current state: !`git status`
        """
      )

    assert {:ok, skill} = Skill.read(path)
    joined = Enum.join(skill.diagnostics, "\n")
    assert joined =~ "allowed-tools"
    assert joined =~ "context: fork"
    assert joined =~ "model override"
    assert joined =~ "dynamic command substitution"
  end

  test "a long skill is accepted; only an absurd file is refused", %{tmp_dir: tmp_dir} do
    long =
      "---\nname: long\ndescription: A long skill.\n---\n" <> String.duplicate("step\n", 8_000)

    assert {:ok, %Skill{name: "long"}} = Skill.read(write(tmp_dir, "long/SKILL.md", long))

    path = write(tmp_dir, "absurd/SKILL.md", String.duplicate("x", 1_048_577))
    assert {:error, reason} = Skill.read(path)
    assert reason =~ "1048577 bytes; limit is 1048576"
  end

  describe "the loader pages a skill longer than one result" do
    alias Lemieux.Extensions.Workspace.SkillTool

    setup %{tmp_dir: tmp_dir} do
      body = Enum.map_join(1..400, "\n", &"step #{&1}: do the thing carefully")

      path =
        write(
          tmp_dir,
          "long/SKILL.md",
          "---\nname: long\ndescription: A long skill.\n---\n#{body}"
        )

      {:ok, skill} = Skill.read(path)
      %{tool: SkillTool.new([skill]), context: %{tool_output_bytes: 5_000}}
    end

    test "parts fit the session's cap, end on whole lines and say what comes next", ctx do
      assert {:ok, first} = SkillTool.run(ctx.tool, %{"name" => "long"}, ctx.context)
      assert byte_size(first) <= 5_000
      assert first =~ "step 1: do the thing carefully"
      assert first =~ ~s(Call skill again with "part": 2)

      [content, _notice] = String.split(first, "\n\n[Skill long:", parts: 2)
      assert String.ends_with?(content, "carefully")
    end

    test "the parts together are the whole skill, in order", ctx do
      parts =
        Stream.iterate(1, &(&1 + 1))
        |> Enum.reduce_while([], fn number, parts ->
          {:ok, page} =
            SkillTool.run(ctx.tool, %{"name" => "long", "part" => number}, ctx.context)

          if page =~ "the end.]", do: {:halt, [page | parts]}, else: {:cont, [page | parts]}
        end)
        |> Enum.reverse()

      joined = Enum.join(parts, "\n")
      assert joined =~ "step 1: do the thing"
      assert joined =~ "step 400: do the thing"
      assert position(joined, "step 200:") < position(joined, "step 201:")
    end

    test "a part past the end says how many there are", ctx do
      assert {:error, message} =
               SkillTool.run(ctx.tool, %{"name" => "long", "part" => 99}, ctx.context)

      assert message =~ "has"
      assert message =~ "parts"
    end

    test "without a cap in the context, a skill that fits is returned whole", ctx do
      assert {:ok, whole} = SkillTool.run(ctx.tool, %{"name" => "long"}, %{})
      assert whole =~ "step 400"
      refute whole =~ "[Skill long:"
    end
  end

  defp position(string, match), do: string |> :binary.match(match) |> elem(0)

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end
end
