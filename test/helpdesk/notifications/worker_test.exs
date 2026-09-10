defmodule Helpdesk.Notifications.WorkerTest do
  use Helpdesk.DataCase
  alias Helpdesk.Notifications.{Notification, OutboxEvent, Worker}
  alias Helpdesk.Accounts.User
  alias Helpdesk.Support.Ticket

  setup do
    user =
      Repo.insert!(%User{
        id: Ash.UUID.generate(),
        email: "#{Ash.UUID.generate()}@example.com",
        first_name: "Test",
        last_name: "User",
        hashed_password: "unused",
        role: :customer,
        status: :active
      })

    ticket =
      Ash.create!(
        Ticket,
        %{title: "Test ticket", description: "Please help with this", priority: :medium},
        action: :create_ticket,
        actor: user
      )

    event =
      Ash.create!(
        OutboxEvent,
        %{
          source_event_id: Ash.UUID.generate(),
          ticket_id: ticket.id,
          kind: :resolved,
          candidate_recipient_ids: [user.id, user.id],
          occurred_at: DateTime.utc_now()
        },
        action: :enqueue,
        authorize?: false
      )

    %{user: user, ticket: ticket, event: event}
  end

  test "fan-out is durable, deduplicated and broadcasts after processing", ctx do
    Phoenix.PubSub.subscribe(Helpdesk.PubSub, "notifications:user:#{ctx.user.id}")
    Worker.run_once()
    assert_receive :notifications_changed
    [notification] = Ash.read!(Notification, actor: ctx.user)
    assert notification.read_at == nil
    assert Repo.get!(OutboxEvent, ctx.event.id).status == :processed
    Worker.run_once()
    assert length(Ash.read!(Notification, actor: ctx.user)) == 1
    refute_receive :notifications_changed
  end

  test "disabled accounts receive nothing even with a stale actor", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.user, status: :disabled))
    Worker.run_once()
    assert Ash.read!(Notification, authorize?: false) == []
    assert Ash.read!(Notification, actor: ctx.user) == []
  end

  test "paginated queries and counts share visibility, including stale actor status", ctx do
    Worker.run_once()
    assert {:ok, 1} = Helpdesk.Notifications.unread_count(ctx.user)
    assert {:ok, %{results: [notification]}} = Helpdesk.Notifications.list_notifications(ctx.user)
    assert {:ok, _} = Helpdesk.Notifications.mark_read(ctx.user, notification.id)
    assert {:ok, 0} = Helpdesk.Notifications.unread_count(ctx.user)
    Repo.update!(Ecto.Changeset.change(ctx.user, status: :disabled))
    assert Ash.read!(Notification, actor: ctx.user) == []
    assert {:ok, 0} = Helpdesk.Notifications.unread_count(ctx.user)
  end

  test "customers cannot see internal-note notifications even if misrouted", ctx do
    Ash.create!(
      Notification,
      %{
        outbox_event_id: ctx.event.id,
        recipient_id: ctx.user.id,
        ticket_id: ctx.ticket.id,
        kind: "internal_note"
      },
      action: :deliver,
      authorize?: false
    )

    assert Ash.read!(Notification, actor: ctx.user) == []
    assert {:ok, 0} = Helpdesk.Notifications.unread_count(ctx.user)
  end

  test "reassignment before processing suppresses an old assignment", ctx do
    agent =
      Repo.insert!(%User{
        id: Ash.UUID.generate(),
        email: "#{Ash.UUID.generate()}@example.com",
        first_name: "Agent",
        last_name: "User",
        hashed_password: "unused",
        role: :agent,
        status: :active
      })

    Repo.update!(
      Ecto.Changeset.change(ctx.event, kind: :assigned, candidate_recipient_ids: [agent.id])
    )

    Worker.run_once()
    assert Ash.read!(Notification, authorize?: false) == []
    assert Repo.get!(OutboxEvent, ctx.event.id).status == :processed
  end

  test "read policy follows target ownership and mark_read cannot be used by another user", ctx do
    Worker.run_once()
    [notification] = Ash.read!(Notification, actor: ctx.user)
    stranger = %User{id: Ash.UUID.generate(), status: :active, role: :admin}
    assert Ash.read!(Notification, actor: stranger) == []
    assert {:error, _} = Ash.update(notification, %{}, action: :mark_read, actor: stranger)
    assert Ash.update!(notification, %{}, action: :mark_read, actor: ctx.user).read_at
    Repo.update!(Ecto.Changeset.change(ctx.ticket, reporter_id: nil))
    assert Ash.read!(Notification, actor: ctx.user) == []
  end

  test "fan-out failure is rolled back and scheduled for retry", ctx do
    Ecto.Adapters.SQL.query!(Repo, """
    CREATE TRIGGER fail_notifications BEFORE INSERT ON notifications
    BEGIN SELECT RAISE(ABORT, 'test unavailable'); END
    """)

    now = DateTime.utc_now()
    Worker.run_once(now)
    event = Repo.get!(OutboxEvent, ctx.event.id)
    assert event.status == :pending
    assert event.attempts == 1
    assert DateTime.compare(event.next_attempt_at, now) == :gt
    assert Ash.read!(Notification, authorize?: false) == []
    Ecto.Adapters.SQL.query!(Repo, "DROP TRIGGER fail_notifications")
    Worker.run_once(event.next_attempt_at)
    assert Repo.get!(OutboxEvent, ctx.event.id).status == :processed
  end
end
