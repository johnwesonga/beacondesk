defmodule Helpdesk.Audit.Changes.AppendTicketEvent do
  @moduledoc """
  A change for appending ticket events to the audit trail.
  """
  use Ash.Resource.Change

  alias Helpdesk.Audit.Changes.AppendEvent
  alias Helpdesk.Support.Ticket

  @impl true
  def change(changeset, opts, context) do
    AppendEvent.change(changeset, context.actor, fn %Ticket{} = ticket, actor, changeset ->
      metadata = metadata(changeset, opts[:action])

      if metadata == %{changed_fields: []} do
        :skip
      else
        %{
          action: opts[:action],
          actor_id: actor.id,
          actor_label: to_string(actor.email),
          target_label: ticket.ticket_number,
          ticket_id: ticket.id,
          metadata: metadata
        }
      end
    end)
  end

  defp metadata(%{resource: Ticket, action_type: :update} = changeset, _action) do
    %{
      changed_fields:
        changeset.attributes |> Map.keys() |> Enum.map(&Atom.to_string/1) |> Enum.sort()
    }
  end

  defp metadata(_changeset, _action), do: %{}
end
