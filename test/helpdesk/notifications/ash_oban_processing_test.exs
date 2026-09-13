defmodule Helpdesk.Notifications.AshObanProcessingTest do
  use Helpdesk.DataCase
  use Oban.Testing, repo: Helpdesk.Repo

  alias Helpdesk.Accounts.User
  alias Helpdesk.Notifications.{Notification, OutboxEvent, OutboxEventWorker}
  alias Helpdesk.Support.Ticket

  setup do
    user =
      Repo.insert!(%User{
        id: Ash.UUID.generate(),
        email: "#{Ash.UUID.generate()}@example.com",
        first_name: "AshOban",
        last_name: "Recipient",
        hashed_password: "unused",
        role: :customer,
        status: :active
      })

    ticket =
      Ash.create!(
        Ticket,
        %{
          title: "AshOban processing",
          description: "Exercise the generated notification worker.",
          priority: :medium
        },
        action: :create_ticket,
        actor: user
      )

    event = create_event!(ticket.id, user.id)
    %{event: event, user: user}
  end

  test "generated worker processes an event and rejects its stale job", ctx do
    job = AshOban.run_trigger(ctx.event, :process_notification_event)

    assert job.queue == "notification_outbox"
    assert job.worker == inspect(OutboxEventWorker)
    assert job.max_attempts == 8
    assert job.args[:primary_key] == %{id: ctx.event.id}

    assert {:ok, %OutboxEvent{status: :processed}} =
             perform_job(OutboxEventWorker, job.args)

    assert Ash.get!(OutboxEvent, ctx.event.id, authorize?: false).status == :processed

    assert [%Notification{recipient_id: recipient_id}] =
             Ash.read!(Notification, authorize?: false)

    assert recipient_id == ctx.user.id
    assert {:cancel, :trigger_no_longer_applies} = perform_job(OutboxEventWorker, job.args)
    assert length(Ash.read!(Notification, authorize?: false)) == 1
  end

  test "worker retries failures and invokes the final-error action", ctx do
    Ecto.Adapters.SQL.query!(Repo, """
    CREATE TRIGGER fail_ash_oban_notifications BEFORE INSERT ON notifications
    BEGIN SELECT RAISE(ABORT, 'test unavailable'); END
    """)

    job = AshOban.run_trigger(ctx.event, :process_notification_event)

    assert_raise Ash.Error.Unknown, fn ->
      perform_job(OutboxEventWorker, job.args, attempt: 1, max_attempts: 8)
    end

    retriable = Ash.get!(OutboxEvent, ctx.event.id, authorize?: false)
    assert retriable.status == :pending
    assert retriable.attempts == 0

    assert :ok = perform_job(OutboxEventWorker, job.args, attempt: 8, max_attempts: 8)

    failed = Ash.get!(OutboxEvent, ctx.event.id, authorize?: false)
    assert failed.status == :failed
    assert failed.last_error_code == "processing_failed"
    assert Ash.read!(Notification, authorize?: false) == []
  end

  defp create_event!(ticket_id, recipient_id) do
    Ash.create!(
      OutboxEvent,
      %{
        source_event_id: Ash.UUID.generate(),
        ticket_id: ticket_id,
        kind: :resolved,
        candidate_recipient_ids: [recipient_id],
        occurred_at: DateTime.utc_now()
      },
      action: :enqueue,
      authorize?: false
    )
  end
end
