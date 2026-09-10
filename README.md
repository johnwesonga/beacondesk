# BeaconDesk

A helpdesk application built with Elixir, Phoenix LiveView and Ash Framework.
BeaconDesk provides customer, agent and administrator workspaces for managing
support tickets, conversations, attachments and teams.

## Features

- Ticket queue with pagination, assignment, priority and status management.
- Customer portal and ticket detail pages with messages and attachments.
- Agent inbox with public replies, internal notes and attachment uploads for
  assigned tickets.
- Administrator views for users, teams and team memberships.
- Resource-level authorization for customers, agents and administrators.
- Append-only ticket history and audit events.
- Direct browser uploads to Tigris and authorized attachment downloads.
- Password authentication, account confirmation and password reset.

In-app notifications include a live unread badge, a paginated inbox and read
actions. Email delivery is next. See the [notification specification](docs/notifications-tech-spec.md).

## Stack

- Phoenix 1.8 and LiveView
- Ash, AshAuthentication and AshSqlite
- SQLite for application storage; no PostgreSQL server required
- Tailwind CSS and esbuild
- Swoosh for email and ExAws for S3-compatible storage access

## Local setup

Install Elixir and a compatible Erlang/OTP version. The project declares Elixir
`~> 1.15`; development has used Elixir 1.18 with OTP 27. Native dependencies may
require your platform's compiler/build tools.

### Configure attachment storage

Set the following variables in your shell before running development Mix
commands. `config/dev.exs` requires `AWS_ENDPOINT_URL_S3` even when you are not
uploading files.

```sh
export AWS_ENDPOINT_URL_S3="https://YOUR-S3-ENDPOINT"
export BUCKET_NAME="YOUR-BUCKET"
export AWS_ACCESS_KEY_ID="YOUR-ACCESS-KEY"
export AWS_SECRET_ACCESS_KEY="YOUR-SECRET-KEY"
export AWS_REGION="auto"
```

Use the service endpoint without the bucket name: the uploader constructs
`https://BUCKET.ENDPOINT`. The current storage configuration targets Tigris and
uses region `auto` for ExAws. Keep the signing region consistent with it.

Configure the bucket's CORS rules to allow browser uploads from
`http://localhost:4000`, including `POST` and the required request headers. Use
credentials that can access the configured bucket. Keep credentials out of source
control; `.envrc` is ignored, but must be loaded by your shell or direnv.

### Install and start

```sh
mix setup
mix phx.server
```

For an interactive server session:

```sh
iex -S mix phx.server
```

Open [localhost:4000](http://localhost:4000). Development data is stored in the
`helpdesk_dev` SQLite file at the project root.

### Create your first administrator

The seed script does not create an administrator. Use the provisioning task:

```sh
HELPDESK_ADMIN_PASSWORD="replace-with-a-secure-password" \
  mix helpdesk.user.create admin@example.com \
  --first-name "Jane" --last-name "Smith" --role admin
```

Both name flags are required. Supported roles are `customer`, `agent` and `admin`;
if omitted, the role defaults to `admin`. Passwords must contain at least eight
characters. Use hyphenated flags such as `--first-name` and `--last-name`.

Development confirmation emails are available at
[/dev/mailbox](http://localhost:4000/dev/mailbox). After signing in, administrators
can manage users and teams from the application.

## Application routes

| Route | Purpose |
| --- | --- |
| `/sign-in` | Sign in |
| `/tickets` | Ticket queue; agents are routed to their inbox |
| `/ticket/new` | Create a ticket |
| `/tickets/:id` | Ticket details, messages and attachments |
| `/notifications` | Notification inbox and unread updates |
| `/inbox` | Agent workspace |
| `/portal` | Customer overview |
| `/admin` | Administrator overview |
| `/users` | User management |
| `/teams` | Teams and membership management |
| `/dev/mailbox` | Development email preview |
| `/dev/dashboard` | Development LiveDashboard |

Access depends on the signed-in user's role and resource policies. Ticket access
does not automatically grant access to every internal message or attachment.

## Development commands

```sh
# Run the test suite
mix test

# Run a focused test file
mix test test/helpdesk/support/ticket_test.exs

# Compile, check dependencies, format and test
mix precommit

# Generate migrations after changing Ash resource schemas
mix ash.codegen describe_your_change

# Apply migrations
mix ash.migrate

# Build production assets
MIX_ENV=prod mix assets.deploy
```

Review generated migrations before applying them. SQLite has restrictions on
altering existing columns; adding a required column to a populated table needs
an appropriate database default or a staged backfill.

## Project structure

| Directory | Contents |
| --- | --- |
| `lib/helpdesk/accounts/` | Users, authentication and permission checks |
| `lib/helpdesk/support/` | Tickets, messages, attachments, teams and workflow changes |
| `lib/helpdesk/audit/` | Audit resources and event recording |
| `lib/helpdesk_web/live/` | LiveView workspaces and shared upload flow |
| `lib/helpdesk_web/components/` | Layouts and reusable UI components |
| `assets/js/` | Browser entry point and external uploader |
| `priv/repo/migrations/` | Database migrations |
| `test/` | Resource, policy and web tests |
| `docs/` | Resource design, UI mockups and technical specifications |

## Production configuration

`config/runtime.exs` reads the following settings:

| Variable | Purpose |
| --- | --- |
| `DATABASE_PATH` | Required absolute SQLite path on persistent, writable storage |
| `SECRET_KEY_BASE` | Required Phoenix secret; generate with `mix phx.gen.secret` |
| `TOKEN_SIGNING_SECRET` | Required authentication token signing secret |
| `PHX_HOST` | Public hostname; configure for your deployment |
| `PORT` | HTTP port, default `4000` |
| `POOL_SIZE` | Database pool size, default `10` |
| `PHX_SERVER` | Set to `true` to start the endpoint in a release |
| `DNS_CLUSTER_QUERY` | Optional DNS cluster discovery |

Production uploads also require the storage variables described above. Configure
bucket CORS for the production origin and a production Swoosh delivery adapter;
the default mailer uses local storage. Persist and back up the SQLite database.
The current configuration is a starting point, not a complete deployment setup.

## Documentation

- [Resource and workflow design](docs/helpdesk-description.md)
- [BeaconDesk UI mockup](docs/beacondesk.html)
- [Support authorization notes](docs/support-authorization.md) — historical notes;
  consult current resource policies for implemented behavior.
- [Notifications technical specification](docs/notifications-tech-spec.md) — proposed
  recipient rules, durable delivery, permissions and rollout.
