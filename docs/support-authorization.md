# Support authorization

Users have a `role`: `customer` (the default), `agent`, or `admin`. The role is
not writable through ordinary actions, including registration. Role provisioning
must happen through trusted server code; there is no role-management action yet.

| Resource | Customer | Agent | Admin |
| --- | --- | --- | --- |
| Ticket | Create as reporter; read own tickets | Create as reporter; read own, assigned, and team tickets; update assigned/team tickets | Create as reporter; read and update all |
| Message | Read public replies and reply on own tickets | Read and reply on assigned/team tickets, including internal notes; public access on own reported tickets | Read and reply on all tickets |
| Attachment | Read attachments on own tickets, excluding internal notes | Read attachments on assigned/team tickets, including internal notes | Read all |
| TicketEvent | No access | Read events on assigned/team tickets | Read all |
| Team | No access | Read teams they belong to | Read, create, update |
| TeamMembership | No access | Read own memberships | Read, create, update |

Anonymous callers have no access. These policies cover the currently defined
actions. Attachment upload actions are still to be implemented with their own policies.

Message creation checks the target ticket with an authorized query before the
insert, because this version of AshSqlite does not support Ash's deferred
post-insert policy checks. Authorship comes from the actor.

For non-admins, attachments linked to a message inherit its visibility. When an
attachment also has a ticket ID, it must match the message's ticket ID. Orphaned
attachments are hidden from non-admins.

Ticket event values and metadata are treated as internal. The event creation action is
denied to all ordinary callers, including admins, to prevent fabricated audit
entries. A trusted workflow change may create an event with authorization
disabled only after authorizing the parent operation; it must derive the event
fields itself. `RecordTicketEvent` does this for ticket creation, assignment,
status, priority and detail updates, and message creation. Each changed ticket
field produces an entry with its previous and new values; no-op updates produce
none. Message entries contain the message ID and type, without copying the body.
The parent write and audit inserts share a repository transaction and roll back
together on error. Events have no update or destroy actions.

The project still needs database migrations and a persistent data layer for
Accounts.User. Include `role` and Message's `message_type` when completing that
schema work. Policy tests use temporary SQLite tables until migrations exist.
