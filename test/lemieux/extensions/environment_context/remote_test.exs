defmodule Lemieux.Extensions.EnvironmentContext.RemoteTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extensions.EnvironmentContext.Remote

  test "transport origins strip credentials and suffixes while canonical identities stay stable" do
    for {remote, expected} <- [
          {"https://user:secret@GitHub.com:8443/acme/project.git?token=secret#private",
           "github.com/acme/project"},
          {"http://github.com/acme/project", "github.com/acme/project"},
          {"HTTPS://GitHub.com/acme/project.git", "github.com/acme/project"},
          {"ssh://git@GitHub.com:2222/acme/project.git", "github.com/acme/project"},
          {"git@GitHub.com:acme/project.git", "github.com/acme/project"},
          {"github.com:acme/project.git", "github.com/acme/project"},
          {"git://GitHub.com/acme/project.git", "github.com/acme/project"},
          {"ssh://git@GitLab/acme/project.git", "gitlab/acme/project"},
          {"git@GitLab:acme/project.git", "gitlab/acme/project"},
          {"https://GitLab/acme/project.git", "gitlab/acme/project"},
          {"https://github.com/acme/project.git.git", "github.com/acme/project.git"},
          {"git@github.com:acme/project.git.git", "github.com/acme/project.git"},
          {"github.com/acme/project.git", "github.com/acme/project.git"},
          {"git.example.co.uk/Team/project-name_1", "git.example.co.uk/Team/project-name_1"}
        ] do
      assert Remote.normalize(remote) == expected, remote
      assert Remote.normalize(Remote.normalize(remote)) == expected, remote
    end
  end

  test "local, malformed, ambiguous and unsafe origins abstain" do
    for remote <- [
          nil,
          42,
          "",
          "/work/acme/project.git",
          "../project.git",
          "acme/project",
          "file:///work/acme/project.git",
          "ext::helper secret",
          "ftp://github.com/acme/project",
          "https://github.com/acme/project/extra.git",
          "https://github.com/acme//project.git",
          "https://github.com/./project.git",
          "https://github.com/acme/..",
          "https://github.com/acme/..git",
          "https://github.com/../project.git",
          "github.com/../project",
          "github.com/acme/..",
          "git@github.com:acme/../project.git",
          "https://github.com/acme/%2e%2e",
          "https://github.com/acme/project%0asecret",
          "https://github.com:bad/acme/project.git",
          "https://github.com:99999/acme/project.git",
          "https://github.com:0/acme/project.git",
          "https://user@other@github.com/acme/project.git",
          "https://github.com/acme/project.git\nsecret",
          "https://github.com/acme/project.git\r",
          "https://github.com/acme/project.git\0",
          "https://github.com/acme/project.git other",
          "https://github.com/acme\\project.git",
          "https://github.com/acme/project@secret",
          "https://github.com/acme/project.git/",
          "https://-github.com/acme/project.git",
          "https://github..com/acme/project.git",
          "github.com/acme/project?secret",
          "ssh://git@[::1]/acme/project.git",
          <<255>>,
          String.duplicate("a", 4_097),
          "github.com/acme/" <> String.duplicate("a", 200)
        ] do
      assert Remote.normalize(remote) == nil, inspect(remote)
    end
  end
end
