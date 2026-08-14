[
  inputs: [
    "{mix,.formatter,.credo}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "*.{heex,ex,exs}"
  ],
  line_length: 120,
  import_deps: [:phoenix, :phoenix_live_view],
  plugins: [Phoenix.LiveView.HTMLFormatter],
  locals_without_parens: [
    plug: :*,
    pipe_through: :*,
    forward: :*,
    get: :*,
    post: :*,
    put: :*,
    patch: :*,
    delete: :*,
    options: :*,
    resources: :*,
    socket: :*,
    channel: :*,
    live: :*,
    live_session: :*
  ]
]
