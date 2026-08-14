# Clean up artifacts from previous test runs.
File.rm("erl_crash.dump")

# Exclude all special-purpose tags from bare `mix test`.
# Run explicitly: mix test --include chaos --include security etc.
ExUnit.configure(exclude: [:integration, :scenario, :load, :chaos, :security, :migration, :property])

ExUnit.start()
