defmodule Helpdesk.Audit.Changes.AppendAttachmentEvent do
  @moduledoc """
  A change for appending message events to the audit trail.
  """
  use Ash.Resource.Change

  alias Helpdesk.Audit.Changes.AppendEvent
  alias Helpdesk.Repo
  alias Helpdesk.Support.{Attachment, Ticket}

  @impl true
  def change(changeset, opts, context) do
    AppendEvent.change(changeset, context.actor, fn %Attachment{} = attachment,
                                                    actor,
                                                    _changeset ->
      ticket = Repo.get!(Ticket, attachment.ticket_id)

      %{
        action: opts[:action],
        actor_id: actor.id,
        actor_label: to_string(actor.email),
        target_label: ticket.ticket_number,
        ticket_id: ticket.id,
        metadata: %{
          attachment_id: attachment.id
        }
      }
    end)
  end
end
