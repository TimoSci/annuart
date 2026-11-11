import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :annuart, Annuart.Repo,
  database: Path.expand("../annuart_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :annuart, AnnuartWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "J7jcoBKUN9XbH+dffc1E+PCWXJUntRsnF5hPscXRzOIbPxa3evS9HtjxFTbsbW09",
  server: false

# Print only warnings and errors during test
# Dev-only wallet bundle. Never enable outside dev and test.
config :annuart, dev_wallet: true

# Preset so the app does not read a deployment file during tests.
config :annuart, :chain, chain_id: 31337, rpc_url: "http://127.0.0.1:8545", contracts: []

# Tests never touch a chain: all RPC goes through the stub.
config :annuart, :rpc, Annuart.RpcStub

config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
