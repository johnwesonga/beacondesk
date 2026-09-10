defmodule Helpdesk.Support.Changes.RecordTicketEvent do
  use Ash.Resource.Change

  alias Helpdesk.Repo
  alias Helpdesk.Support.{Message, Ticket, TicketEvent}

  @ticket_fields [
    assignee_id: :assigned,
    team_id: :team_changed,
    status: :status_changed,
    priority: :priority_changed,
    title: :details_changed,
    category: :details_changed,
    due_at: :details_changed
  ]

  @impl true
  def change(changeset, _opts, context) do
    # AshSqlite does not advertise transaction support to Ash. Explicitly
    # include both the parent write and all audit entries in one transaction.
    Ash.Changeset.around_action(changeset, fn changeset, callback ->
      Repo.transaction(fn ->
        original =
          if changeset.resource == Ticket and changeset.action_type == :update do
            Repo.get!(Ticket, changeset.data.id)
          end

        case callback.(changeset) do
          {:ok, record, completed_changeset, _instructions} = result ->
            # Read the persisted ticket so partially selected or stale input
            # records cannot introduce false changes into the audit trail.
            audit_record =
              if changeset.resource == Ticket, do: Repo.get!(Ticket, record.id), else: record

            for event <- events(original, audit_record, completed_changeset) do
              case Ash.create(TicketEvent, event,
                     action: :create_ticket_event,
                     actor: context.actor,
                     authorize?: false
                   ) do
                {:ok, _event} -> :ok
                {:error, error} -> Repo.rollback(error)
              end
            end

            result

          {:error, error} ->
            Repo.rollback(error)
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, error} -> {:error, error}
      end
    end)
  end

  defp events(nil, %Ticket{} = ticket, %{action_type: :create} = changeset) do
    [%{ticket_id: ticket.id, event_type: :ticket_created, metadata: metadata(changeset)}]
  end

  defp events(%Ticket{} = original, %Ticket{} = ticket, changeset) do
    for {field, event_type} <- @ticket_fields,
        old_value <- [Map.fetch!(original, field)],
        new_value <- [Map.fetch!(ticket, field)],
        old_value != new_value do
      %{
        ticket_id: ticket.id,
        event_type: event_type,
        field_name: Atom.to_string(field),
        old_value: serialize(old_value),
        new_value: serialize(new_value),
        metadata: metadata(changeset)
      }
    end
  end

  defp events(nil, %Message{} = message, %{action_type: :create} = changeset) do
    [
      %{
        ticket_id: message.ticket_id,
        event_type: :message_added,
        metadata:
          Map.merge(metadata(changeset), %{
            "message_id" => message.id,
            "message_type" => Atom.to_string(message.message_type)
          })
      }
    ]
  end

  defp metadata(changeset), do: %{"action" => Atom.to_string(changeset.action.name)}

  defp serialize(nil), do: nil
  defp serialize(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp serialize(value), do: to_string(value)
end
