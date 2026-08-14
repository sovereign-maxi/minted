defmodule MintedWeb.ErrorHTML do
  @moduledoc """
  Renders error pages as standalone HTML. No nav, no footer —
  just the error code and a message on a black background.
  """

  use Phoenix.Component

  def render("404.html", _assigns) do
    error_page("404", "Nothing here.")
  end

  def render("500.html", _assigns) do
    error_page("500", "Something went wrong.")
  end

  def render(template, _assigns) do
    code = template |> String.split(".") |> hd()
    error_page(code, "Something went wrong.")
  end

  defp error_page(code, message) do
    assigns = %{code: code, message: message}

    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{@code}</title>
        <style>
          * { margin: 0; padding: 0; box-sizing: border-box; }
          body {
            background: #0a0a0a;
            font-family: 'JetBrains Mono', 'Consolas', monospace;
            display: flex;
            align-items: center;
            justify-content: center;
            flex-direction: column;
            min-height: 100vh;
            gap: 1rem;
          }
          .code {
            font-size: 5rem;
            font-weight: 700;
            color: #10b981;
            letter-spacing: 0.05em;
          }
          .message {
            font-size: 1.1rem;
            font-weight: 400;
            color: #8b8b8b;
            letter-spacing: 0.02em;
          }
        </style>
      </head>
      <body>
        <div class="code">{@code}</div>
        <div class="message">{@message}</div>
      </body>
    </html>
    """
  end
end
