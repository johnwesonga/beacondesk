defmodule Helpdesk.Notifications.OutboxEventTest do
  use Helpdesk.DataCase

  alias Helpdesk.Accounts.User
  alias Helpdesk.Notifications.OutboxEvent

  test "trusted enqueue persists a pending event and enforces occurrence uniqueness" do
    attributes = attributes()
    event = Ash.create!(OutboxEvent, attributes, action: :enqueue, authorize?: false)

    assert event.status == :pending
    assert event.attempts == 0
    assert event.schema_version == 1
    assert event.candidate_recipient_ids == attributes.candidate_recipient_ids
    assert Ash.get!(OutboxEvent, event.id, authorize?: false).payload == %{}

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.create(OutboxEvent, attributes, action: :enqueue, authorize?: false)
  end

  test "ordinary actors including administrators cannot enqueue or read events" do
    Ash.create!(OutboxEvent, attributes(), action: :enqueue, authorize?: false)

    for role <- [:customer, :agent, :admin] do
      actor = %User{id: Ash.UUID.generate(), role: role, status: :active}

      assert {:error, %Ash.Error.Forbidden{}} =
               Ash.create(OutboxEvent, attributes(), action: :enqueue, actor: actor)

      assert {:ok, []} = Ash.read(OutboxEvent, actor: actor)
    end

    assert {:ok, []} = Ash.read(OutboxEvent)
  end

  test "enqueue rolls back with its surrounding repository transaction" do
    assert {:error, :parent_failed} =
             Repo.transaction(fn ->
               Ash.create!(OutboxEvent, attributes(), action: :enqueue, authorize?: false)
               Repo.rollback(:parent_failed)
             end)

    assert Ash.read!(OutboxEvent, authorize?: false) == []
  end

  test "enqueue cannot accept worker state from input" do
    assert {:error, %Ash.Error.Invalid{}} =
             Ash.create(OutboxEvent, Map.put(attributes(), :status, :processed),
               action: :enqueue,
               authorize?: false
             )
  end

  defp attributes do
    %{
      source_event_id: Ash.UUID.generate(),
      ticket_id: Ash.UUID.generate(),
      kind: :assigned,
      candidate_recipient_ids: [Ash.UUID.generate()],
      occurred_at: DateTime.utc_now()
    }
  end
end
