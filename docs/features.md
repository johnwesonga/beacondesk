# BeaconDesk feature list

This document collects the proposed helpdesk features and a suggested delivery
order. It is a planning backlog, not a commitment to implement every item.
Statuses reflect the work discussed and implemented as of 2026-09-10.

## Existing foundation

- Customer, agent and administrator workspaces.
- Ticket creation, editing, assignment, priorities and status changes.
- Team and user management, including team memberships.
- Public replies, internal notes and ticket attachments.
- Ticket history and audit events.
- Resource policies and capability-based authorization.
- In-app notifications with durable event capture, background processing,
  unread counts, pagination and read actions.

## Proposed features

### 1. Notifications and unread tracking

**Status:** In-app notifications implemented; email and ticket-level unread
tracking proposed.

Help customers and agents notice updates that need a response.

- Add email notifications for assignments, replies and relevant status changes.
- Let users choose which notification categories send email.
- Track the last viewed conversation per user so queues can identify tickets
  with unseen replies independently of notification read state.
- Later, add mentions, watchers and notification digests.

**First increment:** Email preferences and durable email delivery for the existing
notification events. See [Notifications technical specification](notifications-tech-spec.md).

### 2. SLA targets and escalations

**Status:** Proposed.

Make response expectations visible and identify tickets that are overdue.

- Define first-response and resolution targets by priority or team.
- Show due-soon and overdue indicators in queues and ticket details.
- Define business hours, time zones and which waiting states pause a timer.
- Notify the assignee or escalate to a designated team when a target is breached.
- Report compliance against the targets that applied to each ticket.

**First increment:** First-response deadlines and overdue indicators, with explicit
clock rules, before introducing automated escalation.

### 3. Ticket lifecycle improvements

**Status:** Basic status changes exist; workflow refinements proposed.

Make it clear who needs to act next and prevent inconsistent transitions.

- Define allowed transitions between new, open, waiting, resolved and closed.
- Require a resolution summary when resolving a ticket.
- Reopen a resolved ticket when the customer replies, subject to an agreed policy.
- Support snoozing and reminders for tickets waiting on an external response.
- Consider automatic closure after a configurable resolved period.

**First increment:** A transition matrix enforced in resource actions, with tests
for resolution, reopening and timestamp behavior.

### 4. Canned replies and macros

**Status:** Proposed.

Reduce repetitive work while keeping the agent in control of the response.

- Save reusable reply templates for individuals or teams.
- Search and insert templates into the reply composer.
- Support a small set of validated placeholders, such as ticket number.
- Add macros that combine a prepared reply with assignment, priority or status
  changes, with a preview before execution.

**First increment:** Team-shared canned replies that agents can edit before sending.

### 5. Email-to-ticket integration

**Status:** Proposed; separate from outbound notification emails.

Allow customers to open and continue support conversations through email.

- Create tickets from messages sent to a support address.
- Associate replies with the correct existing conversation.
- Import permitted attachments through the existing attachment workflow.
- Deduplicate inbound messages and handle bounces, automatic replies and loops.
- Establish sender verification and threading rules before accepting replies.

**First increment:** One inbound support mailbox that creates tickets reliably;
threaded replies follow as a separate change.

### 6. Tags, search and saved views

**Status:** Proposed extensions to the existing queues.

Help staff organize and find work without repeatedly configuring filters.

- Add ticket tags and tag management.
- Search by ticket number, title and conversation content, respecting visibility.
- Combine team, assignee, status, priority, tag and date filters.
- Save personal views and share selected views with a team.
- Include views such as unassigned, awaiting customer and overdue.

**First increment:** Tags and saved queue filters; expand search separately.

### 7. Bulk ticket actions

**Status:** Proposed.

Make queue maintenance faster for authorized staff.

- Select multiple tickets for assignment, priority changes, tagging or closure.
- Show the scope and requested change before execution.
- Authorize and validate each ticket independently.
- Report successful and failed items without hiding partial failures.
- Record audit events and avoid excessive notification fan-out.

**First increment:** Bulk assignment with explicit selection and per-ticket results.

### 8. Customer satisfaction feedback

**Status:** Proposed.

Collect feedback after support is delivered.

- Invite customers to rate a resolved ticket.
- Offer a short optional comment.
- Prevent duplicate submissions and define when surveys are sent after reopening.
- Show response rates and ratings by team and period.
- Give staff a way to follow up on negative feedback.

**First increment:** One rating and optional comment per resolution survey.

### 9. Knowledge base and self-service

**Status:** Proposed; extends the customer help area.

Let customers resolve common problems and give agents reusable reference material.

- Create articles with categories, search and publication status.
- Separate public articles from internal support documentation.
- Let agents link articles from replies and canned responses.
- Suggest relevant articles during ticket creation.
- Track article helpfulness and identify content that needs improvement.

**First increment:** Published public articles with categories and search.

### 10. Operational reporting

**Status:** Proposed extensions to the administrator overview.

Help administrators understand workload and service outcomes.

- Track backlog, ticket volume and workload by team and assignee.
- Measure first-response time, resolution time and reopen rate.
- Add SLA compliance and satisfaction metrics when those features exist.
- Filter by date range and export authorized results.
- Define metric calculations, including business hours and reopened tickets,
  before using them to compare teams.

**First increment:** Backlog and response-time trends with documented definitions.

## Suggested delivery order

| Stage | Features | Reason |
| --- | --- | --- |
| 1 | Finish notifications; lifecycle rules | Complete the update loop and establish reliable workflow events |
| 2 | SLA targets; canned replies | Improve responsiveness and reduce repetitive work |
| 3 | Tags, saved views and bulk actions | Make larger ticket queues easier to manage |
| 4 | Email-to-ticket integration | Extend intake once routing and notifications are stable |
| 5 | Satisfaction surveys; knowledge base; reporting expansion | Measure outcomes and support self-service |

Each feature should be delivered in small changes: resource model and policies,
workflow integration, UI, then optional automation. Confirm the detailed scope
before starting a feature's technical specification.

## Supporting improvements

These support the roadmap rather than forming separate customer-facing features:

- Apply disabled-account restrictions consistently across resource actions.
- Keep assignment rules enforced at the resource layer, including active users,
  active teams and valid team membership.
- Review permissions on every new search, bulk operation, export and background
  delivery path; ticket access alone may not permit reading internal messages.
- Add operational visibility for failed background work and controlled retries.
- Keep audit records distinct from user notifications and analytics.
