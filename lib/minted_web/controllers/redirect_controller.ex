defmodule MintedWeb.RedirectController do
  use MintedWeb, :controller

  def to_wallet(conn, _params) do
    redirect(conn, to: "/wallet")
  end
end
