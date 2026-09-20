defmodule HelpdeskWeb.TicketUploads do
  @moduledoc "Shared external upload configuration and ticket attachment persistence."
  alias Helpdesk.AttachmentStore

  def allow(socket, callback \\ &__MODULE__.presign/2, name \\ :attachments) do
    Phoenix.LiveView.allow_upload(socket, name,
      accept: ~w(.png .jpeg .jpg .webp .pdf .doc),
      max_entries: 3,
      external: callback,
      auto_upload: false
    )
  end

  def presign(entry, socket, name \\ :attachments) do
    {:ok,
     AttachmentStore.presigned_upload_form_url(
       entry,
       socket.assigns.uploads[name].max_file_size
     ), socket}
  end

  # Caller wraps ticket changes and all attachment writes in one Repo transaction.
  def persist!(ticket, entries, actor) do
    persist!(%{ticket_id: ticket.id}, :attach_to_ticket, entries, actor)
  end

  def persist_message!(message, entries, actor) do
    persist!(%{message_id: message.id}, :attach_to_message, entries, actor)
  end

  defp persist!(parent, action, entries, actor) do
    Enum.each(entries, fn entry ->
      attributes = %{
        file_name: entry.client_name,
        file_path: AttachmentStore.entry_url(entry),
        storage_key: AttachmentStore.s3_filepath(entry),
        content_type: entry.client_type,
        byte_size: entry.client_size
      }

      case Ash.create(Helpdesk.Support.Attachment, Map.merge(attributes, parent),
             action: action,
             actor: actor
           ) do
        {:ok, _} -> :ok
        {:error, _} -> Helpdesk.Repo.rollback(:attachment_failed)
      end
    end)
  end

  def consume(socket, name \\ :attachments) do
    Phoenix.LiveView.consume_uploaded_entries(socket, name, fn _, entry ->
      {:ok, entry.ref}
    end)
  end
end
