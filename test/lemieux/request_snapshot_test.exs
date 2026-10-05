defmodule Lemieux.RequestSnapshotTest do
  use ExUnit.Case, async: true

  alias Lemieux.Entry
  alias Lemieux.Request
  alias Lemieux.RequestSnapshot

  test "captures the resolved provider-neutral request and redacts transport secrets" do
    user = Entry.new(:user, %{"text" => "fix it"})

    snapshot =
      RequestSnapshot.build(
        Request.new("test:model",
          system: "be useful",
          entries: [user],
          tools: [Lemieux.Tools.Read],
          params: [temperature: 0.2, api_key: "secret"],
          output_schema: [status: [type: :string, required: true]]
        ),
        id: "r1"
      )

    assert snapshot["id"] == "r1"
    assert snapshot["entry_ids"] == [user.id]
    assert snapshot["params"] == %{"api_key" => "[redacted]", "temperature" => 0.2}

    assert snapshot["output_schema"] == [
             ["status", [["type", "string"], ["required", true]]]
           ]

    assert [%{"name" => "read", "schema" => %{"type" => "object"}}] = snapshot["tools"]
    # The serialized schemas are measured and digested, not stored a third
    # time: they are the `tools` list, encoded.
    serialized = JSON.encode!(snapshot["tools"])
    refute Map.has_key?(snapshot["catalog"], "serialized")
    assert snapshot["catalog"]["bytes"] == byte_size(serialized)

    assert snapshot["catalog"]["sha256"] ==
             :crypto.hash(:sha256, serialized) |> Base.encode16(case: :lower)

    assert snapshot["catalog"]["model"] == "test:model"
    assert snapshot["catalog"]["tokenizer"] == nil
    assert snapshot["catalog"]["token_count"] == nil
    assert byte_size(snapshot["catalog"]["sha256"]) == 64

    assert [catalog_tool] = snapshot["catalog"]["tools"]
    assert catalog_tool["enabled"] == true
    assert catalog_tool["descriptor"]["identity"]["name"] == "read"
    assert byte_size(catalog_tool["descriptor"]["digest"]) == 64
    assert byte_size(snapshot["system_sha256"]) == 64
    assert byte_size(snapshot["sha256"]) == 64
    assert RequestSnapshot.verify(snapshot) == :ok

    assert snapshot |> Map.put("model", "tampered:model") |> RequestSnapshot.verify() ==
             {:error, :digest_mismatch}
  end

  test "the canonical digest stays equal when only the snapshot identity changes" do
    request = Request.new("test:model", entries: [Entry.new(:user, %{"text" => "hi"})])

    first = RequestSnapshot.build(request, id: "one")
    second = RequestSnapshot.build(request, id: "two")

    assert first["sha256"] == second["sha256"]
    assert Map.drop(first, ["id", "sha256"]) == Map.drop(second, ["id", "sha256"])
  end

  test "records enabled and disabled descriptors plus an exact host token measurement" do
    request = Request.new("test:model", tools: [Lemieux.Tools.Read])

    snapshot =
      RequestSnapshot.build(request,
        catalog: [Lemieux.Tools.Read, Lemieux.Tools.Write],
        tool_profile: %{"id" => "shared", "enabled_by" => %{"actor" => "admin"}},
        token_counter: fn "test:model", bytes ->
          assert is_binary(bytes)
          {:ok, "fixture-tokenizer", 123}
        end
      )

    assert snapshot["catalog"]["profile"]["id"] == "shared"
    assert snapshot["catalog"]["tokenizer"] == "fixture-tokenizer"
    assert snapshot["catalog"]["token_count"] == 123

    assert Enum.map(
             snapshot["catalog"]["tools"],
             &{&1["descriptor"]["identity"]["name"], &1["enabled"]}
           ) == [
             {"read", true},
             {"write", false}
           ]
  end
end
