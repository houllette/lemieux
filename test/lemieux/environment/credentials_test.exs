defmodule Lemieux.Environment.CredentialsTest do
  use ExUnit.Case, async: true

  alias Lemieux.Environment.Credentials

  describe "sensitive?/2" do
    test "inheriting withholds nothing" do
      refute Credentials.sensitive?("OPENAI_API_KEY", :inherit)
    end

    test "scrubbing withholds names containing KEY, TOKEN or SECRET in any case" do
      policy = {:scrub, []}

      for name <- ~w(OPENAI_API_KEY GH_TOKEN AWS_SECRET_ACCESS_KEY client_secret api_key) do
        assert Credentials.sensitive?(name, policy), name
      end

      for name <- ~w(PATH HOME LANG EDITOR) do
        refute Credentials.sensitive?(name, policy), name
      end
    end

    # Database clients read their password from the environment by these
    # names, and they passed the scrub before PASSWORD and PASSWD were markers.
    test "scrubbing withholds password-shaped names too" do
      policy = {:scrub, []}

      for name <- ~w(PASSWORD DB_PASSWORD PGPASSWORD MYSQL_PASSWD db_passwd
                     AZURE_CLIENT_CERTIFICATE_PASSWORD) do
        assert Credentials.sensitive?(name, policy), name
      end

      # The heuristic reads names, not values: a connection string carrying a
      # password, a variable that merely points at a key file, or a password
      # under an abbreviation no marker covers, passes — as the moduledoc says.
      for name <-
            ~w(DATABASE_URL GOOGLE_APPLICATION_CREDENTIALS SSH_AUTH_SOCK MYSQL_PWD PWD OLDPWD) do
        refute Credentials.sensitive?(name, policy), name
      end
    end

    test "an allow entry keeps a name, exactly or by glob" do
      policy = {:scrub, ["GH_TOKEN", "AWS_*", "*_PUBLIC_KEY"]}

      refute Credentials.sensitive?("GH_TOKEN", policy)
      refute Credentials.sensitive?("AWS_SECRET_ACCESS_KEY", policy)
      refute Credentials.sensitive?("SSH_PUBLIC_KEY", policy)
      assert Credentials.sensitive?("GITHUB_TOKEN", policy)
      # Case matters in an allow entry, as it does in the names themselves.
      assert Credentials.sensitive?("gh_token", policy)
    end

    test "glob metacharacters other than * are literal" do
      assert Credentials.sensitive?("MY_KEY", {:scrub, ["MY.KEY"]})
      refute Credentials.sensitive?("MY.KEY", {:scrub, ["MY.KEY"]})
    end
  end

  describe "overrides/2" do
    test "unsets every sensitive variable, in a stable order" do
      env = %{
        "PATH" => "/bin",
        "ZAI_API_KEY" => "z",
        "ANTHROPIC_API_KEY" => "a",
        "GH_TOKEN" => "g"
      }

      assert Credentials.overrides({:scrub, ["GH_TOKEN"]}, env) == [
               {"ANTHROPIC_API_KEY", false},
               {"ZAI_API_KEY", false}
             ]
    end

    test "inherits by default" do
      assert Credentials.overrides(:inherit, %{"OPENAI_API_KEY" => "k"}) == []
    end
  end

  describe "policy/1" do
    test "accepts the canonical forms and configuration shorthands" do
      assert Credentials.policy(:inherit) == {:ok, :inherit}
      assert Credentials.policy(nil) == {:ok, :inherit}
      assert Credentials.policy(false) == {:ok, :inherit}
      assert Credentials.policy(true) == {:ok, {:scrub, []}}
      assert Credentials.policy({:scrub, ["X"]}) == {:ok, {:scrub, ["X"]}}
    end

    test "refuses anything else rather than falling back to inheriting" do
      assert {:error, _message} = Credentials.policy(:scrub)
      assert {:error, _message} = Credentials.policy({:scrub, [:atom]})
    end
  end
end
