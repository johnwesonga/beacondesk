import Config
config :helpdesk, notification_worker_enabled: false
config :helpdesk, notification_ash_oban_enqueue_enabled: true
config :helpdesk, Oban, testing: :manual
config :helpdesk, token_signing_secret: "zdCwA+HfJe3VeEnscypAgnr6YsP96R8v"
config :bcrypt_elixir, log_rounds: 1
config :ash, policies: [show_policy_breakdowns?: true], disable_async?: true

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :helpdesk, Helpdesk.Repo,
  database: Path.expand("../helpdesk_test#{System.get_env("MIX_TEST_PARTITION")}", __DIR__),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :helpdesk, HelpdeskWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "/cneCjTTZN4Kt9cMj7KF0Oc+GXsao9xRsFCi7iQl8R4f1k9EX/xJbKo4b5jsgFsW",
  server: false

# In test we don't send emails
config :helpdesk, Helpdesk.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
