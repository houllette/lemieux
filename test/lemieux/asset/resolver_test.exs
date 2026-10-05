defmodule Lemieux.Asset.ResolverTest do
  use ExUnit.Case, async: true

  alias Lemieux.Asset.Resolver
  alias Lemieux.Asset.Version

  test "resolves all layers without allowing a higher layer to weaken safety" do
    release = version(:release, :release, %{"network" => "deny"}, "release")
    host = version(:host, :global, %{"filesystem" => "workspace"}, "host")
    tenant = version(:tenant, :tenant, %{}, "tenant")
    project = version(:project, :project, %{"network" => "allow"}, "project")
    session = version(:session, :task, %{}, "session")

    assert {:ok, resolved} = Resolver.resolve([session, project, tenant, host, release])

    assert Enum.map(resolved.versions, & &1.layer) == [
             :release,
             :host,
             :tenant,
             :project,
             :session
           ]

    assert resolved.safety == %{"filesystem" => "workspace", "network" => "deny"}
    assert [%{key: "network", kept: "deny", rejected: "allow"}] = resolved.conflicts
  end

  test "enforces aggregate byte and token budgets" do
    version = version(:project, :project, %{}, String.duplicate("x", 20))

    assert {:error, {:size_budget_exceeded, 20, 10}} =
             Resolver.resolve([version], max_bytes: 10)

    assert {:error, {:token_budget_exceeded, 7, 6}} =
             Resolver.resolve([%{version | token_count: 7}], max_tokens: 6)
  end

  defp version(layer, scope, safety, content) do
    attrs = %{
      type: :project_instruction,
      layer: layer,
      scope: scope,
      content: content,
      safety: safety,
      tenant_id: if(scope == :tenant, do: "tenant"),
      project_id: if(scope in [:project, :task], do: "project")
    }

    {:ok, version} = Version.new(attrs)
    version
  end
end
