# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :annuart,
  ecto_repos: [Annuart.Repo],
  generators: [timestamp_type: :utc_datetime]

# Configure the endpoint
config :annuart, AnnuartWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: AnnuartWeb.ErrorHTML, json: AnnuartWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Annuart.PubSub,
  live_view: [signing_salt: "IclR9d8d"]

# Configure esbuild (the version is required). Two bundles: the app bundle,
# and a dev-only bundle (dev wallet, mock FHE) that the root layout references
# only when :dev_wallet is on. esnext is needed by the FHE libraries.
esbuild_args = ~w(--bundle --target=esnext --outdir=../priv/static/assets
  --external:/fonts/* --external:/images/* --alias:@=.)

esbuild_env = %{
  "NODE_PATH" => [
    Path.expand("../deps", __DIR__),
    Path.expand("../assets/node_modules", __DIR__),
    Mix.Project.build_path()
  ]
}

config :esbuild,
  version: "0.28.2",
  annuart: [
    args: ["js/app.js" | esbuild_args],
    cd: Path.expand("../assets", __DIR__),
    env: esbuild_env
  ],
  # The dev bundle is ESM (loaded with type="module", which defers like the
  # app bundle and keeps document order): the relayer SDK that the mock needs
  # uses source-phase imports, which esbuild cannot emit as an IIFE. And
  # @fhevm/mock-utils imports the SDK's Node entry; the web entry exports the
  # same names (web/docs/fhe-browser-spike.md).
  dev: [
    args: [
      "js/dev.js",
      "--format=esm",
      "--alias:@zama-fhe/relayer-sdk/node=@zama-fhe/relayer-sdk/web" | esbuild_args
    ],
    cd: Path.expand("../assets", __DIR__),
    env: esbuild_env
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  annuart: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
