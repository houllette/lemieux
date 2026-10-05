defmodule Shop.Router do
  use Plug.Router

  pipeline :api do
    plug Shop.Auth.Verify
  end

  pipeline :admin do
    plug Shop.Admin.Guard
  end

  scope "/api" do
    pipe_through :api
    get "/orders", Shop.Orders.Controller, :index
  end

  scope "/admin" do
    pipe_through :admin
    get "/reports", Shop.Admin.Reports, :index
  end
end
