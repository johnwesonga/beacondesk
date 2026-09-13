defmodule Helpdesk.Notifications.CaptureTest do
  use Helpdesk.DataCase
  use Oban.Testing, repo: Helpdesk.Repo

  alias Helpdesk.Accounts.User
  alias Helpdesk.Notifications.{OutboxEvent, OutboxEventWorker}
  alias Helpdesk.Support.{Message, Team, TeamMembership, Ticket}

  setup do
    reporter = user(:customer)
    agent = user(:agent)
    admin = user(:admin)
    team = Ash.create!(Team, %{name: Ash.UUID.generate()}, authorize?: false)
    Ash.create!(TeamMembership, %{team_id: team.id, user_id: agent.id}, authorize?: false)
    %{reporter: reporter, agent: agent, admin: admin, team: team}
  end

  test "creation snapshots team recipients and does not create an initial reply", ctx do
    ticket = ticket(ctx)
    [event] = events()
    assert event.kind == :ticket_created
    assert event.ticket_id == ticket.id
    assert event.candidate_recipient_ids == [ctx.agent.id]
    assert event.message_id == nil

    assert_enqueued(
      worker: OutboxEventWorker,
      queue: :notification_outbox,
      args: %{primary_key: %{id: event.id}}
    )
  end

  test "assignment suppresses self alerts and no-op assignments", ctx do
    ticket = ticket(ctx)
    ticket = Ash.update!(ticket, %{assignee_id: ctx.agent.id}, action: :assign, actor: ctx.agent)
    assigned = Enum.filter(events(), &(&1.kind == :assigned))
    assert [%{candidate_recipient_ids: []}] = assigned
    Ash.update!(ticket, %{assignee_id: ctx.agent.id}, action: :assign, actor: ctx.agent)
    assert length(events()) == 2
  end

  test "public replies route to reporter while internal notes never do", ctx do
    ticket = ticket(ctx)

    for action <- [:add_reply, :add_internal_note] do
      Ash.create!(Message, %{ticket_id: ticket.id, body: "Support response", source: :web},
        action: action,
        actor: ctx.admin
      )
    end

    reply = Enum.find(events(), &(&1.kind == :public_reply))
    note = Enum.find(events(), &(&1.kind == :internal_note))
    assert Enum.sort(reply.candidate_recipient_ids) == Enum.sort([ctx.reporter.id, ctx.agent.id])
    assert note.candidate_recipient_ids == [ctx.agent.id]
    assert reply.payload == %{"email_recipient_ids" => [ctx.reporter.id]}
    assert reply.message_id != nil
  end

  test "disabled team members are excluded and pending candidates remain a snapshot", ctx do
    ticket(ctx)
    Repo.update!(Ecto.Changeset.change(ctx.agent, status: :disabled))
    ticket(ctx)

    assert Enum.sort(Enum.map(events(), & &1.candidate_recipient_ids)) ==
             Enum.sort([[], [ctx.agent.id]])
  end

  test "status changes notify reporter and outer rollback removes ticket and outbox", ctx do
    ticket = ticket(ctx)
    Ash.update!(ticket, %{status: :resolved}, action: :change_status, actor: ctx.admin)
    event = Enum.find(events(), &(&1.kind == :resolved))
    assert event.candidate_recipient_ids == [ctx.reporter.id]

    assert event.payload == %{
             "old_status" => "new",
             "new_status" => "resolved",
             "email_recipient_ids" => [ctx.reporter.id]
           }

    before = length(events())
    jobs_before = length(all_enqueued(worker: OutboxEventWorker))

    assert {:error, :failed} =
             Repo.transaction(fn ->
               ticket(ctx)
               Repo.rollback(:failed)
             end)

    assert length(events()) == before
    assert length(Ash.read!(Ticket, authorize?: false)) == 1
    assert length(all_enqueued(worker: OutboxEventWorker)) == jobs_before
  end

  test "outbox insert failure rolls back the ticket write", ctx do
    Ecto.Adapters.SQL.query!(Repo, """
    CREATE TRIGGER fail_notification_capture BEFORE INSERT ON notification_outbox_events
    BEGIN SELECT RAISE(ABORT, 'test outbox unavailable'); END
    """)

    assert {:error, _} =
             Ash.create(Ticket, params(ctx),
               action: :create_ticket,
               actor: ctx.reporter,
               authorize?: false
             )

    assert Ash.read!(Ticket, authorize?: false) == []
    assert Ash.read!(Helpdesk.Support.TicketEvent, authorize?: false) == []
    assert events() == []
  end

  test "AshOban job insertion failure rolls back ticket and outbox writes", ctx do
    Ecto.Adapters.SQL.query!(Repo, """
    CREATE TRIGGER fail_notification_job_capture BEFORE INSERT ON oban_jobs
    BEGIN SELECT RAISE(ABORT, 'test job queue unavailable'); END
    """)

    assert {:error, _} =
             Ash.create(Ticket, params(ctx),
               action: :create_ticket,
               actor: ctx.reporter,
               authorize?: false
             )

    assert Ash.read!(Ticket, authorize?: false) == []
    assert Ash.read!(Helpdesk.Support.TicketEvent, authorize?: false) == []
    assert events() == []
    assert all_enqueued(worker: OutboxEventWorker) == []
  end

  defp events, do: Ash.read!(OutboxEvent, authorize?: false)

  # Trusted fixture: routing is supplied server-side; customers cannot set it directly.
  defp ticket(ctx),
    do:
      Ash.create!(Ticket, params(ctx),
        action: :create_ticket,
        actor: ctx.reporter,
        authorize?: false
      )

  defp params(ctx),
    do: %{
      title: "Billing question",
      description: "Please explain these fees",
      priority: :medium,
      team_id: ctx.team.id
    }

  defp user(role) do
    Repo.insert!(%User{
      id: Ash.UUID.generate(),
      email: "#{Ash.UUID.generate()}@example.com",
      first_name: "Test",
      last_name: "User",
      hashed_password: "unused",
      role: role,
      status: :active
    })
  end
end
