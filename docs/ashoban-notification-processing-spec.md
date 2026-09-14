# AshOban Notification Processing — Technical Specification

## Status

In progress. Phase 0 adds the Oban/AshOban runtime, migrations, and an explicit
compatibility probe. Existing notification and email workers remain
authoritative until the later cutover phases. Phase 1 adds directly testable
outbox processing and final-error actions while sharing fan-out behavior with
the legacy worker. Phase 2 wires the real generated worker and atomically
enqueues it whenever notification intent is captured in the enabled test path.
Phase 3 replaces the temporary flag with a validated `:legacy`/`:ash_oban`
ownership mode. Development uses AshOban, production defaults safely to legacy
unless `NOTIFICATION_PROCESSING_MODE=ash_oban` is set, and each mode disables
the competing processor.

## Objective

Replace BeaconDesk's custom polling GenServer for processing notification
outbox events with an AshOban-generated worker. The first iteration covers:

```text
OutboxEvent
  → determine current eligible recipients
  → create in-app Notification records
  → create eligible email Delivery records
  → mark OutboxEvent processed
  → broadcast notification invalidations
```

Email provider delivery remains owned by
`Helpdesk.Notifications.EmailWorker` during this implementation.

## Selected workflow

### Replace with AshOban

The first AshOban migration targets `Helpdesk.Notifications.Worker`.

This workflow is a strong fit because:

- work is already represented by an Ash resource;
- eligibility is discoverable from persisted resource state;
- processing is database-only;
- each outbox event can execute independently;
- existing identities provide idempotency;
- AshOban can own record loading, locking, generated jobs, retries, and final
  error dispatch; and
- the custom five-second polling and claim implementation can eventually be
  removed.

### Retain for now

Do not replace `Helpdesk.Notifications.EmailWorker` in this iteration. Email
delivery includes external side effects and currently provides:

- a persistent delivery lease;
- recovery of expired leases;
- a bounded provider timeout;
- provider idempotency keys;
- transient and permanent error classification;
- exponential backoff with jitter;
- final-attempt handling; and
- delivery-time routing, access, preference, and account checks.

Moving it immediately would be a larger behavioral migration. AshOban would
replace its orchestration, but it would not eliminate most of that business and
safety logic.

## Ownership boundary

AshOban owns:

- generating the outbox worker;
- loading an `OutboxEvent` by primary key;
- serializing processing of the record;
- retrying unexpected failures;
- calling the final-error action; and
- Oban job lifecycle and diagnostics.

BeaconDesk owns:

- capturing notification intent transactionally;
- recipient calculation;
- ticket and message visibility checks;
- actor exclusion;
- notification and delivery creation;
- idempotency identities;
- marking an outbox event processed or failed;
- PubSub invalidation after commit; and
- safe error codes and telemetry.

## Outbox resource changes

Extend `Helpdesk.Notifications.OutboxEvent` with AshOban:

```elixir
use Ash.Resource,
  ...,
  extensions: [AshOban]
```

Add internal `:process` and `:processing_failed` update actions.

### Process action

The `:process` action must:

1. Require `status == :pending`.
2. Re-evaluate current recipients and resource access.
3. Exclude the originating actor.
4. Upsert one `Notification` per event and recipient.
5. Upsert one email `Delivery` where email remains eligible.
6. Set `status: :processed`, `processed_at`, and clear
   `last_error_code`.
7. Broadcast private invalidations only after transaction commit.

The existing unique identities remain authoritative:

```text
Notification: outbox_event_id + recipient_id
Delivery: notification_id + channel
```

Repeated execution must therefore remain safe.

### Final-error action

The `:processing_failed` action should only:

- require the event to remain pending;
- set `status: :failed`;
- set `last_error_code: "processing_failed"`;
- avoid storing raw exceptions; and
- emit bounded telemetry.

It must not repeat recipient processing or perform complex cleanup.

## Proposed trigger

The target design is conceptually:

```elixir
oban do
  triggers do
    trigger :process_notification_event do
      action :process
      where expr(status == :pending)
      read_action :read
      worker_read_action :read
      scheduler_cron false
      queue :notification_outbox
      max_attempts 8
      on_error :processing_failed
      trigger_once? true
      actor_persister :none

      worker_module_name Helpdesk.Notifications.OutboxEventWorker
    end
  end
end
```

Verify the exact DSL against the installed AshOban version. Stable generated
module names prevent refactors from stranding persisted jobs.

## Enqueue strategy

Use `scheduler_cron false` and explicitly enqueue the generated worker when the
outbox record is created.

The enqueue must participate in the same database transaction as the
originating ticket operation and `OutboxEvent` insert. This preserves the
current guarantee:

```text
ticket mutation + audit + outbox event + Oban job
either all commit or all roll back
```

Phase 0 must prove that `AshOban.run_trigger/3` participates in the current
SQLite transaction. If this cannot be guaranteed, retain periodic
reconciliation as a safety mechanism or keep the existing poller.

Do not use a minute-based cron trigger as the primary mechanism because that
would regress notification latency from roughly five seconds to as much as one
minute.

## Processing transaction

Outbox fan-out remains one short SQLite transaction:

```text
lock pending OutboxEvent
→ calculate eligible recipients
→ upsert notifications
→ upsert email delivery records
→ mark event processed
→ commit
→ broadcast invalidations
```

No email provider calls may occur inside this transaction. This avoids holding
a SQLite write lock during network I/O.

## Authorization and privacy

- Browser and ordinary actor access to `OutboxEvent` remains forbidden.
- The AshOban interaction receives a narrowly scoped policy bypass.
- The trigger uses no persisted user actor.
- Recipient authorization is re-evaluated using each recipient as the actor.
- Generated jobs contain only the outbox primary key and required AshOban
  metadata.
- Candidate lists and ticket payloads must not enter job arguments.

## Failure semantics

| Condition | Outcome |
| --- | --- |
| Event already processed | Cancel or no-op |
| Recipient inactive | Omit recipient |
| Routing changed | Omit recipient |
| Ticket or message inaccessible | Omit recipient |
| No eligible recipients | Process successfully with zero deliveries |
| Notification identity conflict | Treat as idempotent success |
| Transient database failure | Retry through Oban |
| Attempts exhausted | Mark event failed with a safe code |
| Event manually failed or removed | Stale job must not process it |

Expected recipient changes are not job failures.

## SQLite and Oban configuration

Add Oban and AshOban dependencies and configure `Oban.Engines.Lite` with a
dedicated queue:

```elixir
queues: [notification_outbox: 1]
```

Start with concurrency one because processing performs multiple SQLite writes.
Configure:

- active Oban leadership;
- a standard pruning service;
- a reasonable SQLite `busy_timeout`;
- stable generated worker module names; and
- manual Oban testing in the test environment.

The implementation must verify that overdue work is staged after restart and
that temporary SQLite write contention does not lose jobs.

## Operations

Continue supporting:

```elixir
Helpdesk.Notifications.Operations.status(admin)
Helpdesk.Notifications.Operations.retry_failed(admin, :outbox, event_id)
```

Retrying a failed event should:

1. Set it back to pending.
2. Reset its safe failure state.
3. Explicitly invoke the AshOban trigger.
4. Retain the original outbox and notification identities.

Oban Web may be added for job inspection, but the domain resource remains the
source of truth for notification outcomes.

## Telemetry

Emit bounded telemetry for scheduled, processed, and failed outbox work.

Allowed metadata:

- notification kind;
- outcome;
- attempt number; and
- safe failure code.

Measurements:

- count;
- queue delay;
- processing duration;
- recipient count;
- notification count; and
- email-delivery count.

Do not include email addresses, ticket subjects, message bodies, candidate
recipient IDs, user IDs, raw exceptions, or full Oban arguments.

## Implementation phases

### Phase 0 — Compatibility spike

- Add Oban and AshOban.
- Configure `Oban.Engines.Lite`.
- Add an experimental trigger and generated worker.
- Verify that job arguments contain only the outbox ID.
- Verify that enqueue and outbox creation roll back together.
- Verify SQLite locking, leadership, staging, and retries.
- Keep both existing workers active in production.

### Phase 1 — Resource actions

- Implement `OutboxEvent.process`.
- Move deterministic fan-out from `Worker` into a change or service invoked by
  the action.
- Implement the minimal final-error action.
- Preserve identities and after-commit PubSub behavior.
- Test the actions directly without Oban.

### Phase 2 — AshOban execution

- Add the real trigger.
- Enqueue committed events explicitly.
- Test generated jobs with Oban manual testing.
- Test retry, final failure, stale jobs, and repeated execution.
- Keep the custom worker disabled only in tests covering AshOban.

### Phase 3 — Controlled cutover

- Add a configuration flag selecting `:legacy` or `:ash_oban` processing.
- Enable AshOban in development and staging.
- Compare processing latency, failed counts, and duplicate behavior.
- Ensure only one processor owns outbox events at a time.
- Remove `Notifications.Worker` from the supervision tree after validation.

Implemented through the single `:notification_processing_mode` setting:

- `:legacy` supervises `Notifications.Worker`, does not enqueue new AshOban
  jobs, and starts Oban with queues disabled;
- `:ash_oban` omits `Notifications.Worker`, atomically enqueues each captured
  event, and enables the bounded `notification_outbox` queue;
- development and tests use `:ash_oban`;
- production defaults to `:legacy`; and
- staging or production opt in with
  `NOTIFICATION_PROCESSING_MODE=ash_oban` followed by an application restart.

Rollback requires setting `NOTIFICATION_PROCESSING_MODE=legacy` and restarting.
Pending outbox rows are then handled by the legacy poller. AshOban jobs remain
durable but cannot execute while its queue is disabled; if AshOban is enabled
again later, jobs whose records were already processed are rejected as stale.

### Phase 4 — Operational hardening

- Update administrator retry operations.
- Add backlog and oldest-pending metrics.
- Document Oban Web and IEx troubleshooting.
- Test restart recovery and overdue jobs.
- Tune SQLite pool size, queue concurrency, and busy timeout.
- Remove legacy polling configuration.

### Phase 5 — Reassess email delivery

Evaluate `Delivery` as a separate AshOban migration. Do not assume that success
with database-only outbox processing makes provider delivery a drop-in
conversion.

## Acceptance criteria

- Ticket mutation and outbox job creation remain atomic.
- One event creates at most one notification per recipient.
- One notification creates at most one delivery per channel.
- Actors never notify themselves.
- Current routing and authorization are rechecked.
- Internal messages never reach unauthorized customers.
- Zero-recipient events complete successfully.
- Failures retry without duplicating notifications.
- Final errors store only safe codes.
- PubSub occurs only after committed notification writes.
- No network I/O occurs inside the SQLite fan-out transaction.
- The old and new processors never run simultaneously.
- Restarted applications process pending and overdue events.
- All focused tests and `mix precommit` pass.
