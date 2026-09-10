defmodule HelpdeskWeb.TicketUploads do
  @moduledoc "Shared external upload configuration and ticket attachment persistence."
  alias Helpdesk.AttachmentStore

  def allow(socket, callback \\ &__MODULE__.presign/2) do
    Phoenix.LiveView.allow_upload(socket, :attachments,
      accept: ~w(.png .jpeg .jpg .webp .pdf .doc),
      max_entries: 3,
      external: callback,
      auto_upload: false
    )
  end

  def presign(entry, socket) do
    {:ok,
     AttachmentStore.presigned_upload_form_url(
       entry,
       socket.assigns.uploads.attachments.max_file_size
     ), socket}
  end

  # Caller wraps ticket changes and all attachment writes in one Repo transaction.
  def persist!(ticket, entries, actor) do
    Enum.each(entries, fn entry ->
      attributes = %{
        ticket_id: ticket.id,
        file_name: entry.client_name,
        file_path: AttachmentStore.entry_url(entry),
        storage_key: AttachmentStore.s3_filepath(entry),
        content_type: entry.client_type,
        byte_size: entry.client_size
      }

      case Ash.create(Helpdesk.Support.Attachment, attributes,
             action: :attach_to_ticket,
             actor: actor
           ) do
        {:ok, _} -> :ok
        {:error, _} -> Helpdesk.Repo.rollback(:attachment_failed)
      end
    end)
  end

  def consume(socket) do
    Phoenix.LiveView.consume_uploaded_entries(socket, :attachments, fn _, entry ->
      {:ok, entry.ref}
    end)
  end
end
