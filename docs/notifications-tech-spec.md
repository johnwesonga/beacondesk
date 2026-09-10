# Helpdesk notifications technical specification

Status: proposed · Date: 2026-09-10

## Objective

Notify customers and support staff when a ticket needs their attention, with a
persistent in-app inbox and optional email delivery. Notifications must respect
ticket and message visibility, survive process restarts, and never deliver an
event for a rolled-back ticket operation.

This document specifies the target design. Implementation is being delivered in
small changes; completed infrastructure does not yet imply user-facing delivery.

### Implementation progress

1. **Complete: outbox foundation.** Notifications domain, internal OutboxEvent
   resource, SQLite migration/snapshot and persistence/authorization tests.
   No ticket actions enqueue events yet. IDs are stored as internal references;
   the next step must derive them from persisted resources, never browser input.
2. **Next: event capture.** Recipient selection and transactional enqueue from
   RecordTicketEvent, including no-op and initial-description suppression.
3. **Pending: in-app processing.** Notification resource, visibility policies,
   idempotent fan-out and supervised outbox worker.
4. **Pending: LiveView UI.** Bell, unread count, pagination and read actions.
5. **Pending: email.** Preferences, delivery resource, retries and monitoring.

## Existing integration points

- `Helpdesk.Support.Changes.RecordTicketEvent` records ticket creation, changed
  fields and messages in the same explicit repository transaction as the parent
  operation. It compares persisted records and skips unchanged fields.
- `Helpdesk.Audit.Changes.AppendEvent` independently writes audit events inside
  repository transactions. Notifications must not subscribe to both event paths,
  which would duplicate messages.
- `Helpdesk.PubSub` already runs under the application supervisor.
- Swoosh is already a dependency. Reuse the application's mail infrastructure.
- Storage uses AshSqlite and `Helpdesk.Repo`. Keep durable queue records in the
  same database as tickets. No background job dependency is currently declared.
- Message policies are narrower than ticket policies: agents' ability to read
  all tickets does not grant access to every internal note or attachment.

Use current resource policies as the authorization reference. The existing
`docs/support-authorization.md` contains historical statements that should not
be copied into the new feature without checking them against the resources.

## Scope

First release:

- Assignment, team routing, public reply, internal note and selected status
  notifications.
- Header bell, unread count, paginated notification list, mark one/all as read.
- Live updates for connected users through PubSub.
- Email delivery with preferences, retries and operational visibility.

Later releases: mentions, watchers, attachment-only notifications, SLA reminders,
digests, browser push, SMS and external integrations. A ticket reply may link to
its attachments, but attachments do not produce separate first-release alerts.
Authentication and password-reset emails remain outside notification preferences.

## Event and recipient rules

The following are proposed product defaults. “Team” means active agent/admin
members of the ticket's active team. “Owner” means its active assignee; when
unassigned, use the team. A disabled assignee is treated as unavailable for
routing. An inactive team receives no team fan-out.

| Event | Candidate recipients | Default channels |
| --- | --- | --- |
| Ticket created | Owner, otherwise team | In-app; email for direct assignee only |
| Assignee changed to a user | New assignee | In-app and email |
| Assignee removed | Team | In-app |
| Team changed | New team, only when unassigned | In-app |
| Public reply from reporter | Owner, otherwise team | In-app; email for direct assignee only |
| Public reply from another user | Reporter and owner | In-app and email for reporter/direct assignee |
| Internal note added | Owner, otherwise team; staff only | In-app |
| Status becomes waiting_on_customer | Reporter | In-app and email |
| Status becomes resolved or closed | Reporter | In-app and email |
| Status leaves resolved/closed for an active status | Reporter and owner | In-app and email for reporter/direct assignee |

Rules applied to every row:

1. Exclude the actor. Account confirmation emails are unrelated to this rule.
2. Union recipient IDs before creating notifications; multiple memberships or
   roles never create duplicate notifications for one occurrence.
3. Require an active account and current access to the target. For message events,
   authorize the message itself, not just its ticket. Internal notes additionally
   require a staff role even if some broader future policy permits access.
4. Administrators do not receive everything automatically. They receive alerts
   when explicitly assigned, a reporter or a relevant team member.
5. Skip no-op updates. Routine title, category and priority edits do not notify in
   the first release; their audit records remain available.
6. If assignment and team change together, prioritize the assignment alert and
   suppress team fan-out when the final ticket has an assignee.
7. An event with no eligible recipients is successfully processed with zero
   notifications. Record a metric so unstaffed queues can be noticed.

Capture candidate recipient IDs from the persisted final ticket state and team
memberships inside the originating transaction. Delayed processing must not
notify a newly assigned agent about an old assignment. Recheck eligibility before
fan-out, reading and email delivery; loss of access can remove a candidate, but
does not add new candidates retroactively.

## Persistence model

Add an Ash domain, `Helpdesk.Notifications`, using the existing SQLite repository.
Expose user actions through the domain; reserve queue mutations for trusted
server code. All timestamps use UTC with microsecond precision.

| Resource/table | Principal fields | Constraints and indexes |
| --- | --- | --- |
| `OutboxEvent` / `notification_outbox_events` | UUID id; source ticket-event ID; kind; ticket_id; optional message_id and actor_id; candidate recipient IDs; minimal payload; occurred_at; processed_at; retry/lease fields | Unique source event ID + kind; index pending work by status and next_attempt_at |
| `Notification` / `notifications` | UUID id; outbox_event_id; recipient_id; ticket_id; optional message_id; kind; read_at; inserted_at | Unique outbox_event_id + recipient_id; indexes recipient_id + inserted_at + id, and recipient_id + read_at |
| `Delivery` / `notification_deliveries` | UUID id; notification_id; channel; status; attempts; next_attempt_at; lease_token; lease_expires_at; sent_at; last_error_code; optional provider_message_id | Unique notification_id + channel; index status + next_attempt_at |
| `Preference` / `notification_preferences` | UUID id; user_id; kind; email_enabled; timestamps | Unique user_id + kind |

Outbox retry/lease fields follow the delivery worker protocol below. Outbox status
is `pending`, `processing`, `processed` or `failed`. Delivery status is `pending`,
`sending`, `sent`, `skipped` or `failed`; retries return to `pending`.

The in-app notification row is itself the durable in-app delivery; do not create
a second delivery row for PubSub. Initially `Delivery.channel` supports only email.
Missing preferences use the matrix defaults. In-app notifications stay enabled;
users can disable email per notification kind. Store preferences per user, never
accept another user's ID from a browser form.

Payloads contain IDs, relevant old/new status and a schema version, not message
bodies, attachment URLs, passwords or arbitrary changeset metadata. Render ticket
labels from authorized current data. Candidate IDs are internal queue data.

Read state is independent of email status and ticket status. Opening a ticket
does not automatically clear every notification about that ticket in this release.

## Producing events atomically

Extend the successful event-creation path in `RecordTicketEvent` to call a trusted
`Helpdesk.Notifications.enqueue_ticket_event/2` function after each `TicketEvent`
insert. Pass server-derived before/after context for recipient selection and
coalescing. The function ignores event types outside the matrix.

Use the saved ticket-event UUID as the stable source identifier. Do not also
enqueue from `Audit.AppendEvent` or from LiveView handlers. This covers browser,
IEx and API actions consistently without relying on a web request ID.

The parent operation, ticket event, audit entry and notification outbox insert
must share the existing outermost `Helpdesk.Repo` transaction and connection.
Enqueue failure rolls back the operation. Preserve the current hook result tuple
and error handling. Do not start Tasks, send email or broadcast inside these
transaction hooks. Nested transaction success is not an outer commit.

The worker discovers committed outbox rows by polling. A later optimization may
wake it after a confirmed outer commit, but correctness must not depend on that
signal. Multiple field events from one action are reduced by the rules above,
using the final ticket state; ordinary detail changes yield no notification.

Initial descriptions created as messages during ticket creation must not generate
an additional “new reply” notification. Explicitly identify that creation path
and enqueue only the ticket-created alert. Verify this with an integration test.

## Processing and delivery

Start a supervised notification worker after `Helpdesk.Repo` and PubSub. For the
initial SQLite deployment, use a small polling worker backed by these tables;
do not introduce a PostgreSQL-dependent queue. A future job adapter can replace
the worker without changing the event/recipient contract.

Proposed defaults: poll every five seconds, claim at most 25 rows, one concurrent
email send, 60-second leases, 15-second provider timeout. Make these configurable.

1. Claim due work in a short database transaction using a conditional update and
   a new lease token. Continue only if the update affected the expected row.
2. Recheck candidate users and target authorization. In one short transaction,
   create notification rows and eligible email delivery rows, then mark the
   outbox event processed. Database unique constraints make repeated work safe.
3. After that transaction commits, broadcast an invalidation to each affected
   user's private topic. A lost broadcast is harmless: the rows already exist.
4. Claim an email delivery and recheck active account, current email preference,
   confirmed email address and target authorization. Mark ineligible deliveries
   `skipped` with a reason. Unconfirmed addresses are skipped, not replayed on
   future confirmation.
5. Deliver outside the database transaction. Persist the outcome only if the
   lease token still matches; expired claims can be reclaimed after a crash.

Use bounded exponential backoff with jitter, starting at 30 seconds and capped
at one hour, with eight total attempts. Retry transient database/provider/network
errors. Permanent provider failures become `failed`; authorization and preference
changes become `skipped`. Exhausted outbox work is visible for operator review.

This is at-least-once processing. A crash after the email provider accepts a
message but before `sent` is stored can produce a duplicate. Pass the delivery
UUID as a provider idempotency key when supported; do not promise exactly-once
email. Never retry the ticket action because an asynchronous email failed.

SQLite transactions must remain short. Never hold a writer lock while contacting
the mail provider. Lease-based claiming must work even if two workers accidentally
start against the same database. Test contention and reclaim behavior explicitly.

## Authorization and privacy

- Notification reads, counts and mark-read actions require an active actor,
  `recipient_id == actor.id` and current access to the referenced ticket/message.
  Administrators do not gain ordinary access to another user's notification inbox.
- Implement visibility in the authorized query, before pagination and counting.
  Do not fetch all notifications and hide unauthorized rows in the template.
- Outbox creation, notification creation and delivery mutations are denied to
  ordinary actors. Trusted worker functions may bypass authorization only for
  internal writes after explicit recipient eligibility checks.
- Reuse underlying resource visibility rules rather than expanding
  `CanAccessTicket` into notification-specific permission logic. Add tests for
  policy differences between tickets, messages and attachments.
- Email uses a generic subject/body, ticket number and authenticated ticket link.
  Do not embed internal-note text, message bodies or presigned attachment URLs.
  Build links from the configured application URL, not a request Host header.
- Target pages and download endpoints authorize every request, including old
  email links. Access revocation after sending cannot retract an email.
- If a target is removed, suppress its pending deliveries and exclude its
  notifications from normal queries. Use explicit cleanup behavior for foreign
  keys rather than accidental cascading deletion of audit history.

## LiveView experience and API

Add a bell to the authenticated `Layouts.app` header and a `/notifications`
LiveView inside the authenticated live session. Use the existing layout, inputs,
icons and styling conventions.

- Show a capped unread badge (`99+`) and an accessible text label.
- List newest first with a stable `inserted_at, id` order, 20 per page using Ash
  pagination. Stream only the current page into the LiveView.
- Include unread/all filters, mark-read per item and mark-all-read.
- Clicking an item marks that notification read and navigates to its authorized
  ticket. Missing or inaccessible targets show a neutral unavailable message.
- Mark-all-read applies to eligible notifications created at or before a captured
  cutoff time, so notifications arriving during the operation remain unread.
- Preferences expose email toggles with the defaults explained to the user.

Proposed domain operations:

```text
list_notifications(actor, filter, page)
unread_count(actor)
mark_read(actor, notification_id)
mark_all_read(actor, cutoff)
update_preferences(actor, attributes)
enqueue_ticket_event(ticket_event, trusted_context)  # internal only
```

Subscribe on connected mount to `notifications:user:<actor.id>`, deriving the ID
from the authenticated session. Broadcast only an invalidation signal. On receipt,
reload the actor's authorized count and visible page; do not trust broadcast
payloads as rendered content. Refresh on reconnect and after read actions so
multiple tabs stay consistent. Coalesce bursts of invalidations.

## Operations and rollout

Configure worker enablement, email enablement, polling, retry settings, sender
and application URL through application/runtime configuration. Tests disable
automatic polling and invoke processing deterministically. Use the existing
development mail adapter for local inspection.

Emit telemetry for pending counts, oldest pending age, processing latency,
delivery successes/retries/failures/skips and zero-recipient events. Log event and
delivery IDs plus sanitized error codes, not email bodies or signed URLs. Provide
an admin-only operational retry command for failed work; it must retain the
original idempotency identities and recheck current eligibility.

Proposed retention: read notifications for 90 days; processed outbox and terminal
delivery records for at least 30 days and while referenced by retained
notifications. Delete children/parents in a deliberate order. Do not replay an
event after its deduplication records have expired. Keep audit retention separate.

Implementation sequence:

1. Add resources, policies, database identities/indexes and enqueue integration.
   Generate and review SQLite migrations; use defaults/backfills if later adding
   required fields to populated tables.
2. Implement deterministic outbox processing and in-app notification queries.
3. Add header/list UI and PubSub invalidations.
4. Add email templates, preferences, retry processing and operational metrics.
5. Enable in-app delivery first, then email after checking recipient behavior in
   staging. Do not backfill historical ticket events into customer notifications.

## Acceptance tests

- Successful ticket mutation persists its outbox event; failure of any ticket,
  audit or enqueue write leaves neither the change nor its notification event.
- Repeated processing creates one notification per event/recipient and one
  email delivery per notification; no-op assignments generate none.
- Team and assignee changes in one action follow the routing/coalescing rules.
- Multiple team memberships do not duplicate alerts; actors never notify
  themselves; creation does not also generate an initial-message reply alert.
- Public replies reach the intended reporter/owner. Customers never receive
  internal-note notifications, even through counts or email subjects.
- An agent who can read a ticket but not its message receives no message alert.
- Removing membership, reassigning a ticket or disabling an account before
  processing prevents delivery when it removes eligibility. Queries hide
  notifications whose target is no longer accessible.
- Recipient changes after enqueue do not redirect historical assignment alerts.
- Email preference changes and unconfirmed addresses suppress queued email.
- Worker crashes, lease expiry, duplicate workers and transient provider failures
  recover without losing committed notifications; duplicate-email limitations
  are tested with a simulated acceptance-before-crash failure.
- PubSub loss/reconnect recovers unread counts from storage. Pagination, mark-read
  and mark-all-read preserve ownership and concurrent new notifications.
- LiveView tests use stable DOM selectors; worker tests use controlled clocks
  and a fake mail adapter rather than sleeps or real external email.

Run focused policy, transaction, worker and LiveView tests, followed by
`mix precommit`, when implementing the feature.
