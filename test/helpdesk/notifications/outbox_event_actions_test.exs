defmodule Helpdesk.Notifications.OutboxEventActionsTest do
  use Helpdesk.DataCase

  alias Helpdesk.Accounts.User
  alias Helpdesk.Notifications.{Notification, OutboxEvent}
  alias Helpdesk.Support.Ticket

  setup do
    user =
      Repo.insert!(%User{
        id: Ash.UUID.generate(),
        email: "#{Ash.UUID.generate()}@example.com",
        first_name: "Test",
        last_name: "Recipient",
        hashed_password: "unused",
        role: :customer,
        status: :active
      })

    ticket =
      Ash.create!(
        Ticket,
        %{
          title: "Action processing",
          description: "Process this notification action test.",
          priority: :medium
        },
        action: :create_ticket,
        actor: user
      )

    event = create_event!(ticket.id, user.id)
    %{event: event, ticket: ticket, user: user}
  end

  test "process fans out once and marks the event processed", ctx do
    Phoenix.PubSub.subscribe(Helpdesk.PubSub, "notifications:user:#{ctx.user.id}")

    processed = Ash.update!(ctx.event, %{}, action: :process, authorize?: false)

    assert processed.status == :processed
    assert processed.attempts == 1
    assert processed.processed_at
    assert processed.last_error_code == nil
    assert_receive :notifications_changed

    assert [%Notification{recipient_id: recipient_id}] =
             Ash.read!(Notification, authorize?: false)

    assert recipient_id == ctx.user.id

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(processed, %{}, action: :process, authorize?: false)

    assert length(Ash.read!(Notification, authorize?: false)) == 1
  end

  test "processing rechecks current account eligibility", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.user, status: :disabled))

    processed = Ash.update!(ctx.event, %{}, action: :process, authorize?: false)

    assert processed.status == :processed
    assert Ash.read!(Notification, authorize?: false) == []
  end

  test "fan-out failure rolls back the state transition", ctx do
    Ecto.Adapters.SQL.query!(Repo, """
    CREATE TRIGGER fail_action_notifications BEFORE INSERT ON notifications
    BEGIN SELECT RAISE(ABORT, 'test unavailable'); END
    """)

    assert {:error, _error} =
             Ash.update(ctx.event, %{}, action: :process, authorize?: false)

    event = Ash.get!(OutboxEvent, ctx.event.id, authorize?: false)
    assert event.status == :pending
    assert event.attempts == 0
    assert event.processed_at == nil
    assert Ash.read!(Notification, authorize?: false) == []
  end

  test "final-error action stores only a bounded failure code", ctx do
    handler_id = "outbox-failure-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler_id,
        [:helpdesk, :notifications, :outbox, :processing_failed],
        fn name, measurements, metadata, test_pid ->
          send(test_pid, {:telemetry, name, measurements, metadata})
        end,
        self()
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    failed =
      Ash.update!(ctx.event, %{}, action: :processing_failed, authorize?: false)

    assert failed.status == :failed
    assert failed.last_error_code == "processing_failed"
    assert failed.processed_at == nil

    assert_receive {:telemetry, [:helpdesk, :notifications, :outbox, :processing_failed],
                    %{count: 1}, %{kind: :resolved, error_code: "processing_failed"}}

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(failed, %{}, action: :processing_failed, authorize?: false)
  end

  defp create_event!(ticket_id, recipient_id) do
    Ash.create!(
      OutboxEvent,
      %{
        source_event_id: Ash.UUID.generate(),
        ticket_id: ticket_id,
        kind: :resolved,
        candidate_recipient_ids: [recipient_id, recipient_id],
        occurred_at: DateTime.utc_now()
      },
      action: :enqueue,
      authorize?: false
    )
  end
end
