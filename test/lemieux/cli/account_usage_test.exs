defmodule Lemieux.CLI.AccountUsageTest do
  use ExUnit.Case, async: true
  alias Lemieux.AccountUsage, as: Report
  alias Lemieux.CLI.AccountUsage
  alias Lemieux.CLI.AccountUsage.Codex
  alias Lemieux.CLI.Config
  alias Lemieux.Conversation
  alias Lemieux.Conversation.Command.Builtin
  alias Lemieux.Conversation.Command.Usage
  alias Lemieux.Conversation.Dispatch

  @moduletag :tmp_dir

  defp options(providers, overrides \\ %{}) do
    Map.merge(
      %{
        config: Config.__struct__(settings: %{"providers" => providers}),
        base_url: nil,
        model: "openrouter:test"
      },
      overrides
    )
  end

  test "queries only configured capabilities and isolates partial permission failures" do
    parent = self()

    request = fn opts ->
      send(parent, {:request, opts})

      case opts[:url] do
        "https://openrouter.ai/api/v1/key" ->
          {:ok,
           %{
             status: 200,
             body: %{
               "data" => %{
                 "usage_monthly" => 4.5,
                 "usage_weekly" => 2,
                 "limit_remaining" => 15.5,
                 "label" => "SECRET-KEY-LABEL"
               }
             }
           }}

        "https://api.openai.com/v1/organization/costs" ->
          {:ok, %{status: 403, body: "private auth error"}}
      end
    end

    options =
      options(%{
        "openrouter" => %{"api_key" => "router-secret"},
        "openai" => %{"usage_api_key" => "admin-secret"},
        "anthropic" => %{},
        "relay" => %{}
      })

    report =
      AccountUsage.fetch(options, request: request, getenv: fn _ -> nil end, now: 1_800_000_000)

    assert_receive {:request, first}
    assert_receive {:request, second}

    assert Enum.sort([first[:url], second[:url]]) == [
             "https://api.openai.com/v1/organization/costs",
             "https://openrouter.ai/api/v1/key"
           ]

    refute_receive {:request, _}, 20
    text = Report.format(report)
    assert text =~ "used 4.50 USD"
    assert text =~ "remaining 15.50 USD"
    assert text =~ "not authorized"
    assert text =~ "separately authorized admin"
    assert text =~ "relay"
    refute text =~ "router-secret"
    refute text =~ "admin-secret"
    refute text =~ "SECRET-KEY-LABEL"
    assert Enum.all?([first, second], &(&1[:retry] == false and &1[:redirect] == false))
  end

  test "reports metered costs in the queried window with explicit scope, and refuses incomplete totals" do
    parent = self()

    request = fn opts ->
      send(parent, {:request, opts})

      {:ok,
       %{
         status: 200,
         body: %{
           "data" => [%{"results" => [%{"amount" => %{"value" => 12.34, "currency" => "usd"}}]}],
           "has_more" => false
         }
       }}
    end

    configured =
      options(
        %{"openai" => %{"usage_api_key" => "admin", "usage_project_id" => "project-test"}},
        %{model: "openai:test"}
      )

    report =
      AccountUsage.fetch(configured,
        request: request,
        getenv: fn _ -> nil end,
        now: 1_800_000_000
      )

    assert [account] = report.accounts
    assert account.scope =~ "selected project"
    assert [window] = account.windows
    assert window.used == 12.34
    assert window.remaining == nil
    assert window.end_at == 1_800_000_000
    assert_receive {:request, request}
    assert List.keyfind(request[:params], "project_ids[]", 0) == {"project_ids[]", "project-test"}
    incomplete = fn _ -> {:ok, %{status: 200, body: %{"data" => [], "has_more" => true}}} end

    assert hd(AccountUsage.fetch(configured, request: incomplete).accounts).message =~
             "incomplete"

    malformed = fn _ ->
      {:ok, %{status: 200, body: %{"data" => [%{"results" => [%{}]}], "has_more" => false}}}
    end

    assert hd(AccountUsage.fetch(configured, request: malformed).accounts).message =~
             "unknown cost"
  end

  test "Anthropic decimal cents convert to USD and exclusions stay visible" do
    request = fn _ ->
      {:ok,
       %{
         status: 200,
         body: %{
           "data" => [%{"results" => [%{"amount" => "123.78912", "currency" => "USD"}]}],
           "has_more" => false
         }
       }}
    end

    report =
      AccountUsage.fetch(
        options(%{"anthropic" => %{"usage_api_key" => "admin"}}, %{model: "anthropic:test"}),
        request: request
      )

    assert [account] = report.accounts
    assert_in_delta hd(account.windows).used, 1.2378912, 0.000001
    assert account.message =~ "Priority Tier"
  end

  test "custom inference endpoints do not send credentials to public billing APIs" do
    parent = self()

    report =
      AccountUsage.fetch(
        options(%{"openrouter" => %{"api_key" => "private"}}, %{
          base_url: "https://custom.invalid/v1"
        }),
        request: fn _ -> send(parent, :contacted) end
      )

    refute_receive :contacted, 20
    assert hd(report.accounts).status == :unavailable
  end

  test "quota windows preserve unknown values and multiple buckets without account metadata" do
    limits = %{
      "rateLimitsByLimitId" => %{
        "a" => %{
          "accountId" => "PRIVATE",
          "primary" => %{
            "usedPercent" => 25,
            "windowDurationMins" => 300,
            "resetsAt" => 1_800_000_000
          },
          "secondary" => %{"usedPercent" => nil}
        },
        "b" => %{"primary" => %{"usedPercent" => 101, "windowDurationMins" => 10_080}}
      }
    }

    assert {:ok, [first, unknown, second]} = Codex.normalize(limits)
    assert first.remaining == 75
    assert first.reset_at == 1_800_000_000
    assert unknown.used == nil and unknown.remaining == nil
    assert second.remaining == 0
    refute inspect([first, unknown, second]) =~ "PRIVATE"
    assert {:error, _} = Codex.normalize(%{})
  end

  test "Codex fixture receives only account RPCs and access token; original sign-in is unchanged",
       ctx do
    token =
      "test." <>
        Base.url_encode64(JSON.encode!(%{"exp" => 1_900_000_000}), padding: false) <> ".sig"

    source = Path.join(ctx.tmp_dir, "auth.json")

    bytes =
      JSON.encode!(%{
        "tokens" => %{
          "access_token" => token,
          "account_id" => "fixture-account",
          "refresh_token" => "MUST-NOT-BE-SENT"
        }
      })

    File.write!(source, bytes)

    assert {:ok, [short, weekly]} =
             Codex.fetch(
               codex_auth: [source: source],
               codex_command: System.find_executable("python3"),
               codex_args: [Path.expand("test/fixtures/codex_usage.py")]
             )

    assert short.remaining == 75
    assert weekly.remaining == 58
    assert weekly.label =~ "10080 minute"
    assert File.read!(source) == bytes
  end

  test "cached reports, stale refresh failures, help registration and mid-turn dispatch" do
    conversation = Conversation.new(model: "test:model")
    now = System.system_time(:second)

    old = %{
      fetched_at: now,
      accounts: [
        %{
          provider: "test",
          scope_key: "scope",
          status: :ok,
          windows: [],
          scope: "account",
          fetched_at: now,
          message: nil
        }
      ]
    }

    assert [{:say, cached}] = Usage.parse("", %{conversation | account_usage: old, busy?: true})
    assert cached =~ "cached"

    assert [{:account_usage, ^old}] =
             Usage.parse("refresh", %{conversation | account_usage: old, busy?: true})

    new = %{
      fetched_at: now + 60,
      accounts: [%{provider: "test", scope_key: "scope", status: :error, message: "timeout"}]
    }

    assert Report.format(Report.merge(new, old)) =~ "STALE"
    refute Report.fresh?(old, now + 60)
    assert Usage in Builtin.all()
    parent = self()

    host =
      Dispatch.new(
        say: fn acc, _ -> acc end,
        write: fn acc, _ -> acc end,
        fold: fn acc, _ -> acc end,
        react: fn acc, _ -> acc end,
        run: fn acc, work ->
          send(parent, {:work, work})
          acc
        end,
        account_usage: fn -> old end
      )

    assert :responsive = Usage.perform(:responsive, host, {:account_usage, nil})
    assert_receive {:work, work}
    assert {:account_usage_result, ^old} = work.()
  end
end
