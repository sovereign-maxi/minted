defmodule MintedAdminWeb.Layouts do
  @moduledoc """
  Layout templates for the admin dashboard.

  Independent of `MintedWeb.Layouts` so wallet-facing surfaces (the
  first-visit welcome modal, in particular) can never leak onto the
  operator's Tor-only dashboard.
  """

  use MintedWeb, :html

  embed_templates "layouts/*"
end
