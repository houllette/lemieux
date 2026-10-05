defmodule Lemieux.MCPCredentialNamesTest do
  # A repository's MCP configuration may not read a credential-shaped
  # variable (`Lemieux.MCP.expand/2`), by the rule of
  # `Lemieux.Environment.Credentials`. Since PASSWORD and PASSWD joined that
  # rule, `expand/2`'s documentation listed only KEY, TOKEN and SECRET; these
  # pin what it says to what it does.
  use ExUnit.Case, async: true

  alias Lemieux.MCP

  test "a project configuration may not read a password-shaped variable" do
    for name <- ~w(DB_PASSWORD PGPASSWORD MYSQL_PASSWD db_passwd) do
      assert {:error, message} = MCP.expand("${#{name}:-fallback}", source: "project")
      assert message =~ "${#{name}}"
    end
  end

  test "one the person allowed, or their own configuration, may" do
    name = "LMX_TEST_UNSET_PASSWORD_#{System.unique_integer([:positive])}"
    reference = "${#{name}:-fallback}"

    assert {:ok, "fallback"} = MCP.expand(reference, source: "project", allow_env: [name])
    assert {:ok, "fallback"} = MCP.expand(reference, source: "personal")
  end

  test "the documentation names every marker the rule applies" do
    {:docs_v1, _anno, _language, _format, _module_doc, _metadata, docs} = Code.fetch_docs(MCP)

    {_kind, _anno, _signature, %{"en" => doc}, _meta} =
      Enum.find(docs, &match?({{:function, :expand, 2}, _, _, _, _}, &1))

    for marker <- ~w(KEY TOKEN SECRET PASSWORD PASSWD), do: assert(doc =~ "`#{marker}`")
  end
end
