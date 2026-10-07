defmodule Lemieux.Extension.RoutesTest do
  use ExUnit.Case, async: true

  alias Lemieux.Extension.Routes
  alias LemieuxTest.StaticRoute

  defmodule NotARoute do
    def available_models(_state, _opts), do: []
  end

  defp relay(name), do: %{name: name, route: {StaticRoute, StaticRoute.new(name: name)}}

  test "a name is lowercase letters, digits and _, starting with a letter" do
    for name <- ["relay", "r2", "my_relay"], do: assert(Routes.valid_name?(name))

    for name <- ["Relay", "2relay", "my-relay", "", "relay:x", :relay, nil],
        do: refute(Routes.valid_name?(name))
  end

  test "validate/1 accepts a list of named routes whose modules are routes" do
    assert Routes.validate([relay("relay"), relay("other")]) == :ok
    assert Routes.validate([]) == :ok
  end

  test "validate/1 names what is wrong with a registration" do
    assert {:error, message} = Routes.validate([relay("Relay")])
    assert message =~ ~s(route name "Relay")

    assert {:error, message} = Routes.validate([%{name: "relay", route: {NotARoute, %{}}}])
    assert message =~ "NotARoute"
    assert message =~ "validate_model/3"

    assert {:error, message} = Routes.validate([%{name: "relay", route: StaticRoute}])
    assert message =~ "{module, state}"

    assert {:error, message} = Routes.validate([relay("relay"), relay("relay")])
    assert message =~ "offered twice"

    assert {:error, message} = Routes.validate(%{name: "relay"})
    assert message =~ "{:ok, [routes]}"
  end
end
