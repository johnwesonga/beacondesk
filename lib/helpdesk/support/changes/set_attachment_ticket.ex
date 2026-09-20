defmodule Helpdesk.Support.Changes.SetAttachmentTicket do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      message =
        Helpdesk.Repo.get!(
          Helpdesk.Support.Message,
          Ash.Changeset.get_attribute(changeset, :message_id)
        )

      Ash.Changeset.force_change_attribute(changeset, :ticket_id, message.ticket_id)
    end)
  end
end
