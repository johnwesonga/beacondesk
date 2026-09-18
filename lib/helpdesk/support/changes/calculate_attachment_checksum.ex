defmodule Helpdesk.Support.Changes.CalculateAttachmentChecksum do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      storage_key = Ash.Changeset.get_attribute(changeset, :storage_key)

      case Helpdesk.AttachmentStore.checksum(storage_key) do
        {:ok, checksum} ->
          Ash.Changeset.force_change_attribute(changeset, :checksum, checksum)

        {:error, _reason} ->
          Ash.Changeset.add_error(changeset,
            field: :checksum,
            message: "could not be calculated from the stored file"
          )
      end
    end)
  end
end
