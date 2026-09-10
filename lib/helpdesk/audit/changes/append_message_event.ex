defmodule Helpdesk.Audit.Changes.AppendMessageEvent do
  @moduledoc """
  A change for appending message events to the audit trail.
  """
  use Ash.Resource.Change

  alias Helpdesk.Audit.Changes.AppendEvent
  alias Helpdesk.Repo
  alias Helpdesk.Support.{Message, Ticket}

  @impl true
  def change(changeset, opts, context) do
    AppendEvent.change(changeset, context.actor, fn %Message{} = message, actor, _changeset ->
      ticket = Repo.get!(Ticket, message.ticket_id)

      %{
        action: opts[:action],
        actor_id: actor.id,
        actor_label: to_string(actor.email),
        target_label: ticket.ticket_number,
        ticket_id: ticket.id,
        metadata: %{
          message_id: message.id,
          message_type: Atom.to_string(message.message_type)
        }
      }
    end)
  end
end
