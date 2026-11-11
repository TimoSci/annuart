defmodule AnnuartWeb.Router do
  use AnnuartWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {AnnuartWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", AnnuartWeb do
    pipe_through :browser

    live_session :public, on_mount: AnnuartWeb.WalletHook do
      live "/", BrowseLive
      live "/enft/:label/:id", EnftLive
      live "/create", CreateLive
      live "/market", MarketLive
      live "/mine", MyEnftsLive
      live "/tokens", TokensLive
    end
  end

  # Other scopes may use custom stacks.
  # scope "/api", AnnuartWeb do
  #   pipe_through :api
  # end
end
