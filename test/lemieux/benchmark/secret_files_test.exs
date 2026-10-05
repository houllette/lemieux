defmodule Lemieux.Benchmark.SecretFilesTest do
  use ExUnit.Case, async: true

  alias Lemieux.Benchmark.SecretFiles

  @moduletag :tmp_dir

  describe "secret?/1" do
    test "names whose purpose is to hold credentials" do
      for name <-
            ~w(.env .env.local .env.production .envrc mise.local.toml .mise.local.toml server.pem
               tls.key cert.p12 store.pfx putty.ppk app.jks release.keystore id_rsa id_ed25519
               id_ecdsa.pub .netrc _netrc .npmrc .pypirc .pgpass .git-credentials credentials.json
               credentials-prod.json .credentials.json client_secret_123.json prod.secret.exs
               erl_crash.dump .ENV ID_RSA config/prod.secret.exs nested/dir/.env) do
        assert SecretFiles.secret?(name), name
      end
    end

    # Cloud SDKs write credentials under names of their own: the AWS shared
    # file has no extension, gcloud's application default does not start with
    # "credentials", and service-account keys are named after the account.
    test "cloud credential files" do
      for name <-
            ~w(.aws/credentials credentials application_default_credentials.json
               serviceAccountKey.json my-project-service-account.json service_account.json
               AuthKey_ABC123.p8) do
        assert SecretFiles.secret?(name), name
      end
    end

    test "ordinary project files, including the documented template" do
      for name <-
            ~w(.env.example README.md mix.exs lib/env.ex lib/keys.ex id.ex id_generator.ex
               credentials.ex credentials_test.exs lib/credentials/store.ex service_account.ex
               config/config.exs .gitignore .formatter.exs keymap.json environment.json
               .envoy) do
        refute SecretFiles.secret?(name), name
      end
    end
  end

  test "find/1 lists secret-shaped files anywhere under a directory", %{tmp_dir: dir} do
    write(dir, "README.md", "hello")
    write(dir, ".env", "TOKEN=fake")
    write(dir, "config/prod.secret.exs", "import Config")
    write(dir, "deep/er/id_rsa", "fake key")

    assert SecretFiles.find(dir) ==
             Enum.sort([".env", "config/prod.secret.exs", "deep/er/id_rsa"])
  end

  describe "copy/2" do
    setup %{tmp_dir: dir} do
      source = Path.join(dir, "source")
      write(source, "lib/app.ex", "defmodule App do end")
      write(source, ".env", "TOKEN=fake")
      write(source, ".env.example", "TOKEN=")
      write(source, "keys/server.key", "fake key")
      write(source, "bin/run", "#!/bin/sh\necho ok\n")
      File.chmod!(Path.join(source, "bin/run"), 0o755)

      %{source: source, destination: Path.join(dir, "fixture")}
    end

    test "leaves secret-shaped files out and says which", ctx do
      assert {:ok, [".env", "keys/server.key"]} = SecretFiles.copy(ctx.source, ctx.destination)

      assert File.read!(Path.join(ctx.destination, "lib/app.ex")) =~ "defmodule App"
      assert File.read!(Path.join(ctx.destination, ".env.example")) == "TOKEN="
      refute File.exists?(Path.join(ctx.destination, ".env"))
      refute File.exists?(Path.join(ctx.destination, "keys/server.key"))
      assert File.dir?(Path.join(ctx.destination, "keys"))
    end

    test "keeps file modes and recreates links rather than following them", ctx do
      File.ln_s!("lib/app.ex", Path.join(ctx.source, "app_link.ex"))
      File.ln_s!(".env", Path.join(ctx.source, "env_link"))
      File.ln_s!("missing.txt", Path.join(ctx.source, ".env.link"))

      assert {:ok, skipped} = SecretFiles.copy(ctx.source, ctx.destination)

      assert ".env.link" in skipped

      assert File.stat!(Path.join(ctx.destination, "bin/run")).mode ==
               File.stat!(Path.join(ctx.source, "bin/run")).mode

      assert {:ok, "lib/app.ex"} = File.read_link(Path.join(ctx.destination, "app_link.ex"))
      # A link with an innocent name is copied as a link: it points at a file
      # the copy does not have, rather than carrying that file's contents.
      assert {:ok, ".env"} = File.read_link(Path.join(ctx.destination, "env_link"))
      refute File.exists?(Path.join(ctx.destination, ".env"))
    end

    test "refuses a destination that already exists", ctx do
      File.mkdir_p!(ctx.destination)

      assert {:error, {:destination_exists, _path}} =
               SecretFiles.copy(ctx.source, ctx.destination)
    end
  end

  defp write(root, relative, contents) do
    path = Path.join(root, relative)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end
end
