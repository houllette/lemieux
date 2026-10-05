defmodule Lemieux.Harness.SnapshotTest do
  use ExUnit.Case, async: true

  alias Lemieux.Harness.Snapshot
  alias Lemieux.Request

  test "semantic identity excludes opaque correlations but complete integrity does not" do
    request = Request.new("test:model", system: "be useful", tools: [Lemieux.Tools.Read])

    left = Snapshot.build(request, correlations: %{"run_id" => "left"})
    right = Snapshot.build(request, correlations: %{"run_id" => "right"})

    assert left.semantic_sha256 == right.semantic_sha256
    refute left.manifest_sha256 == right.manifest_sha256
    assert Snapshot.verify(left) == :ok
    assert {:ok, ^left} = left |> Snapshot.encode!() |> Snapshot.decode()
  end

  test "every behavior-bearing field changes the semantic digest" do
    request =
      Request.new("test:model",
        system: "one",
        tools: [Lemieux.Tools.Read],
        params: [temperature: 0.1]
      )

    base =
      Snapshot.build(request,
        resolved_assets: [%{"id" => "prompt", "sha256" => String.duplicate("a", 64)}],
        hooks: %{"id" => "hooks-v1"},
        workflow: %{"id" => "workflow-v1"},
        context_limits: %{"context_window" => 1_000},
        sandbox_profile: %{"id" => "sandbox-v1"}
      )

    {:ok, runtime_variant} =
      base
      |> Snapshot.to_map()
      |> Map.drop(~w(semantic_sha256 manifest_sha256))
      |> put_in(["runtime", "lemieux_version"], "different-runtime")
      |> Snapshot.new()

    variants = [
      Snapshot.build(%{request | system: "two"},
        resolved_assets: base.resolved_assets,
        hooks: base.hooks,
        workflow: base.workflow,
        context_limits: base.context_limits,
        sandbox_profile: base.sandbox_profile
      ),
      Snapshot.build(%{request | model: "test:other"},
        resolved_assets: base.resolved_assets,
        hooks: base.hooks,
        workflow: base.workflow,
        context_limits: base.context_limits,
        sandbox_profile: base.sandbox_profile
      ),
      Snapshot.build(%{request | params: [temperature: 0.2]},
        resolved_assets: base.resolved_assets,
        hooks: base.hooks,
        workflow: base.workflow,
        context_limits: base.context_limits,
        sandbox_profile: base.sandbox_profile
      ),
      Snapshot.build(request,
        resolved_assets: [%{"id" => "prompt", "sha256" => String.duplicate("b", 64)}],
        hooks: base.hooks,
        workflow: base.workflow,
        context_limits: base.context_limits,
        sandbox_profile: base.sandbox_profile
      ),
      Snapshot.build(request,
        resolved_assets: base.resolved_assets,
        hooks: %{"id" => "hooks-v2"},
        workflow: base.workflow,
        context_limits: base.context_limits,
        sandbox_profile: base.sandbox_profile
      ),
      Snapshot.build(%{request | tools: [Lemieux.Tools.Write]},
        resolved_assets: base.resolved_assets,
        hooks: base.hooks,
        workflow: base.workflow,
        context_limits: base.context_limits,
        sandbox_profile: base.sandbox_profile
      ),
      Snapshot.build(request,
        resolved_assets: base.resolved_assets,
        hooks: base.hooks,
        workflow: base.workflow,
        context_limits: base.context_limits,
        tool_profile: %{"id" => "different-profile"},
        sandbox_profile: base.sandbox_profile
      ),
      runtime_variant
    ]

    assert Enum.all?(variants, &(&1.semantic_sha256 != base.semantic_sha256))
  end

  test "credentials and unsafe transports never enter the snapshot" do
    request =
      Request.new("test:model",
        params: [
          temperature: 0.2,
          api_key: "secret",
          headers: %{authorization: "bearer"},
          provider_options: %{
            "access_token" => "nested-token",
            "client-secret" => "nested-secret",
            "max_tokens" => 500
          }
        ]
      )

    encoded = request |> Snapshot.build() |> Snapshot.encode!()

    assert encoded =~ "temperature"
    refute encoded =~ "secret"
    refute encoded =~ "bearer"
    refute encoded =~ "api_key"
    refute encoded =~ "headers"
    refute encoded =~ "nested-token"
    refute encoded =~ "nested-secret"
    assert encoded =~ "max_tokens"
  end

  test "unknown versions and tampering are rejected" do
    snapshot = Snapshot.build(Request.new("test:model"))
    map = Snapshot.to_map(snapshot)

    assert {:error, {:unsupported_version, 2}} =
             map |> Map.put("schema_version", 2) |> JSON.encode!() |> Snapshot.decode()

    assert {:error, :semantic_digest_mismatch} =
             map |> Map.put("model", "test:tampered") |> Snapshot.verify()

    assert {:error, :digest_mismatch} =
             map |> put_in(["correlations", "run_id"], "tampered") |> Snapshot.verify()
  end
end
