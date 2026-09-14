# AshOban notification operations

## Dashboard

Active administrators can inspect Oban at `/admin/oban`. Anonymous users are
redirected to sign-in, and non-administrator accounts are redirected to the
ticket list. The support operations page at `/admin` summarizes pending,
failed, overdue, and oldest-pending outbox events.

## Confirm the active processor

From a local or remote IEx session:

```elixir
Helpdesk.Notifications.ProcessingMode.current()
Process.whereis(Helpdesk.Notifications.Worker)
Oban.check_queue(queue: :notification_outbox)
```

In `:ash_oban` mode the legacy worker must be `nil` and the Oban queue must be
running. In `:legacy` mode the worker has a PID and Oban queue execution is
disabled.

## Inspect queue health

Load an active administrator and request the bounded operational summary:

```elixir
alias Helpdesk.Accounts.User
alias Helpdesk.Notifications.Operations

admin = Helpdesk.Repo.get!(User, "ADMIN_USER_ID")
Operations.status(admin)
```

Inspect failed outbox records without exposing their payloads:

```elixir
alias Helpdesk.Notifications.OutboxEvent
require Ash.Query

OutboxEvent
|> Ash.Query.filter(status == :failed)
|> Ash.Query.select([:id, :kind, :attempts, :last_error_code, :updated_at])
|> Ash.read!(authorize?: false)
```

## Retry a failed event

```elixir
Helpdesk.Notifications.Operations.retry_failed(admin, :outbox, "OUTBOX_EVENT_ID")
```

Only an active administrator can retry an event. The operation changes a
currently failed row back to pending. In AshOban mode it inserts a new job in
the same transaction with a non-sensitive retry nonce, avoiding conflict with
the completed job from the exhausted attempt. In legacy mode the poller picks
up the pending row.

## Recovery and rollback

Jobs and outbox events are stored in the same SQLite database. After an
application restart, Oban stages persisted available, scheduled, and retryable
jobs. Overdue jobs therefore do not require manual recreation.

To return temporarily to the legacy processor, set:

```text
NOTIFICATION_PROCESSING_MODE=legacy
```

Then restart the application. The Oban queue is disabled before the legacy
poller is supervised, preventing simultaneous ownership. Restore
`ash_oban` and restart after resolving the incident.

## SQLite settings

The notification queue has concurrency `1`, and repository connections use a
five-second busy timeout. Keep notification fan-out free of network calls. If
`Database busy` errors persist, inspect long-running writes before increasing
queue concurrency or the connection pool.
