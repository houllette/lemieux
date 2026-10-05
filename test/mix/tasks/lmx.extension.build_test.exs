defmodule Mix.Tasks.Lmx.Extension.BuildTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Lmx.Extension.Build

  # The task copies beams out of `_build`, so it has to have made them first:
  # without the requirement, a fresh checkout would produce an empty ebin and
  # a manifest that names a module nothing defines.
  test "the task compiles the project before reading its build" do
    assert "compile" in Mix.Task.requirements(Build)
  end

  describe "options/1" do
    test "reads the output, module and name overrides" do
      assert {:ok, options} =
               Build.options(["--output", "/tmp/ext", "--module", "My.Ext", "--name", "audit"])

      assert options[:output] == "/tmp/ext"
      assert options[:module] == "My.Ext"
      assert options[:name] == "audit"
    end

    test "has nothing to say when nothing was asked" do
      assert Build.options([]) == {:ok, []}
    end

    test "names an option it does not know" do
      assert {:error, message} = Build.options(["--nope"])
      assert message =~ "--nope"
    end
  end

  # The lines after a build told everybody to run `lmx --extension-dir …`,
  # including the people following the source route, who have no `lmx`.
  describe "what to run next" do
    @manifest %{"name" => "hello", "module" => "HelloExtension"}

    test "names the installed binary where there is one" do
      assert Build.program(fn "lmx" -> "/usr/local/bin/lmx" end) == "lmx"

      text = Build.next_steps(@manifest, "/x/hello", "lmx")
      assert text =~ "Run it with:  lmx --extension-dir /x/hello"
      assert text =~ "lmx --extension hello"
      refute text =~ "mix lmx"
    end

    test "names mix lmx, from the checkout, where there is none" do
      assert Build.program(fn "lmx" -> nil end) == "mix lmx"

      text = Build.next_steps(@manifest, "/x/hello", "mix lmx")
      assert text =~ "Run it with:  mix lmx --extension-dir /x/hello"
      assert text =~ "mix lmx --extension hello"
      assert text =~ "Lemieux checkout"
    end
  end
end
