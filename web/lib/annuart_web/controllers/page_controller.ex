defmodule AnnuartWeb.PageController do
  use AnnuartWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
