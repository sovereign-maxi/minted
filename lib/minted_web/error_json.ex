defmodule MintedWeb.ErrorJSON do
  @moduledoc false

  def render("404.json", _assigns) do
    %{detail: "Not found", code: 0}
  end

  def render("500.json", _assigns) do
    %{detail: "Internal server error", code: 0}
  end

  def render(template, _assigns) do
    %{detail: Phoenix.Controller.status_message_from_template(template), code: 0}
  end
end
