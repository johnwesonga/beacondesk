defmodule Helpdesk.Notifications.OperationsTest do
  use Helpdesk.DataCase
  use Oban.Testing, repo: Helpdesk.Repo

  alias Helpdesk.Accounts.User
  alias Helpdesk.Notifications.{Operations, OutboxEvent, OutboxEventWorker}

  setup do
    admin = user!(:admin)
    customer = user!(:customer)
    %{admin: admin, customer: customer}
  end

  test "status reports outbox depth and oldest pending age to active administrators", ctx do
    pending = event!()
    failed = event!()
    Ash.update!(failed, %{}, action: :processing_failed, authorize?: false)

    assert {:ok, status} = Operations.status(ctx.admin)
    assert status.outbox == %{pending: 1, failed: 1}
    assert status.oldest_pending_outbox == pending.inserted_at
    assert status.overdue_outbox == 1
    assert {:error, :forbidden} = Operations.status(ctx.customer)
  end

  test "retry resets a failed event and enqueues a distinct AshOban job", ctx do
    event = event!()
    original_job = AshOban.run_trigger(event, :process_notification_event)
    failed = Ash.update!(event, %{}, action: :processing_failed, authorize?: false)

    assert {:ok, 1} = Operations.retry_failed(ctx.admin, :outbox, failed.id)

    pending = Ash.get!(OutboxEvent, failed.id, authorize?: false)
    assert pending.status == :pending
    assert pending.attempts == 0
    assert pending.last_error_code == nil

    jobs =
      all_enqueued(worker: OutboxEventWorker)
      |> Enum.filter(fn job ->
        primary_key = job.args["primary_key"] || job.args[:primary_key]
        primary_key in [%{"id" => event.id}, %{id: event.id}]
      end)

    assert length(jobs) == 2
    assert Enum.any?(jobs, &((&1.args["retry_nonce"] || &1.args[:retry_nonce]) != nil))
    assert original_job.id in Enum.map(jobs, & &1.id)
  end

  test "retry authorization and state checks remain restrictive", ctx do
    pending = event!()

    assert {:error, :forbidden} =
             Operations.retry_failed(ctx.customer, :outbox, pending.id)

    assert {:ok, 0} = Operations.retry_failed(ctx.admin, :outbox, pending.id)
  end

  test "legacy retry leaves job ownership with the poller", ctx do
    previous_mode = Application.fetch_env!(:helpdesk, :notification_processing_mode)
    Application.put_env(:helpdesk, :notification_processing_mode, :legacy)

    on_exit(fn ->
      Application.put_env(:helpdesk, :notification_processing_mode, previous_mode)
    end)

    failed = event!() |> Ash.update!(%{}, action: :processing_failed, authorize?: false)

    assert {:ok, 1} = Operations.retry_failed(ctx.admin, :outbox, failed.id)
    assert all_enqueued(worker: OutboxEventWorker) == []
    assert Ash.get!(OutboxEvent, failed.id, authorize?: false).status == :pending
  end

  defp event! do
    Ash.create!(
      OutboxEvent,
      %{
        source_event_id: Ash.UUID.generate(),
        ticket_id: Ash.UUID.generate(),
        kind: :resolved,
        candidate_recipient_ids: [],
        occurred_at: DateTime.utc_now()
      },
      action: :enqueue,
      authorize?: false
    )
  end

  defp user!(role) do
    Repo.insert!(%User{
      id: Ash.UUID.generate(),
      email: "#{Ash.UUID.generate()}@example.com",
      first_name: "Queue",
      last_name: "Operator",
      hashed_password: "unused",
      role: role,
      status: :active
    })
  end
end
