defmodule Helpdesk.Notifications.AshObanCompatibilityTest do
  use Helpdesk.DataCase
  use Oban.Testing, repo: Helpdesk.Repo

  alias Helpdesk.Notifications.OutboxEvent
  alias Helpdesk.Notifications.OutboxEventCompatibilityWorker

  test "SQLite Oban runtime keeps staging and the bounded notification queue enabled" do
    config = Application.fetch_env!(:helpdesk, Oban)

    assert config[:engine] == Oban.Engines.Lite
    assert config[:queues][:notification_outbox] == 1
    assert Keyword.has_key?(config, :plugins)
    refute config[:stage_interval] == :infinity
  end

  test "explicit trigger enqueues a minimal, bounded job" do
    event = create_event!()

    job = AshOban.run_trigger(event, :compatibility_probe)

    assert job.queue == "notification_outbox"
    assert job.worker == inspect(OutboxEventCompatibilityWorker)
    assert job.max_attempts == 2
    assert job.args[:primary_key] == %{id: event.id}
    refute Map.has_key?(job.args, :candidate_recipient_ids)
    refute Map.has_key?(job.args, :ticket_id)
  end

  test "generated worker can load and update an otherwise private outbox event" do
    event = create_event!()
    job = AshOban.run_trigger(event, :compatibility_probe)

    assert :ok = perform_job(OutboxEventCompatibilityWorker, job.args)
    assert Ash.get!(OutboxEvent, event.id, authorize?: false).status == :pending
  end

  test "job insertion rolls back with the surrounding transaction" do
    assert {:error, :parent_failed} =
             Repo.transaction(fn ->
               event = create_event!()
               AshOban.run_trigger(event, :compatibility_probe)
               Repo.rollback(:parent_failed)
             end)

    assert Ash.read!(OutboxEvent, authorize?: false) == []
    assert all_enqueued(worker: OutboxEventCompatibilityWorker) == []
  end

  defp create_event! do
    Ash.create!(
      OutboxEvent,
      %{
        source_event_id: Ash.UUID.generate(),
        ticket_id: Ash.UUID.generate(),
        kind: :assigned,
        candidate_recipient_ids: [Ash.UUID.generate()],
        occurred_at: DateTime.utc_now()
      },
      action: :enqueue,
      authorize?: false
    )
  end
end
