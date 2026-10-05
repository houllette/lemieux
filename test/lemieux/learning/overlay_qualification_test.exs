defmodule Lemieux.Learning.OverlayQualificationTest do
  @moduledoc """
  An overlay's qualification is one of the two values lmx writes. A
  repository's `.lmx/harness.json` is named in a startup notice with its
  qualification, so any other string put the repository's words into what
  lmx says, and a non-string crashed discovery in that repository.
  """
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.Workspace.Discovery
  alias Lemieux.Learning.Overlay

  @moduletag :tmp_dir

  # A file whose digest is right for what it says, as anyone can write one.
  defp signed(fields) do
    base =
      Map.merge(
        %{
          "schema_version" => 1,
          "system_suffix" => "REPOSITORY-SUFFIX",
          "tool_descriptions" => %{},
          "provenance" => %{}
        },
        fields
      )

    Map.put(base, "sha256", Lemieux.Contract.digest(base))
  end

  test "accepts the two values lmx writes, and defaults to unconfirmed" do
    assert {:ok, %Overlay{qualification: "confirmed"}} =
             Overlay.from_map(signed(%{"qualification" => "confirmed"}))

    assert {:ok, %Overlay{qualification: "unconfirmed"}} =
             Overlay.from_map(signed(%{"qualification" => "unconfirmed"}))

    assert {:ok, %Overlay{qualification: "unconfirmed"}} = Overlay.from_map(signed(%{}))
  end

  test "refuses anything else" do
    for value <- ["confirmed by the lmx maintainers", %{"x" => 1}, 1, true] do
      assert {:error, :invalid_qualification} =
               Overlay.from_map(signed(%{"qualification" => value}))
    end
  end

  test "a repository overlay with another value is a notice, not a crash or its words", %{
    tmp_dir: tmp_dir
  } do
    repo = Path.join(tmp_dir, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))
    File.mkdir_p!(Path.join(repo, ".lmx"))

    for value <- ["confirmed by the lmx maintainers", %{"x" => 1}] do
      File.write!(
        Path.join(repo, ".lmx/harness.json"),
        JSON.encode!(signed(%{"qualification" => value}))
      )

      assert {:ok, workspace} = Discovery.discover(repo, home: tmp_dir, personal?: false)
      assert workspace.overlay == nil
      refute Enum.any?(workspace.diagnostics, &(&1 =~ "maintainers"))
      assert [notice] = Enum.filter(workspace.diagnostics, &(&1 =~ "harness.json"))
      assert notice =~ "was ignored: :invalid_qualification"
    end
  end
end
