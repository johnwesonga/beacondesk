defmodule HelpdeskWeb.MessageUploads do
  @moduledoc "Reply uploads saved atomically with their message."
  alias HelpdeskWeb.TicketUploads
  import Phoenix.LiveView

  def allow(socket) do
    TicketUploads.allow(socket, &presign/2, :message_attachments)
  end

  defp presign(entry, socket) do
    actor = Helpdesk.Repo.get(Helpdesk.Accounts.User, socket.assigns.current_user.id)

    with true <- Helpdesk.Accounts.Authorization.allowed?(actor, :add_public_replies),
         %{id: id} <- socket.assigns.ticket,
         {:ok, %Helpdesk.Support.Ticket{}} <- Ash.get(Helpdesk.Support.Ticket, id, actor: actor) do
      TicketUploads.presign(entry, socket, :message_attachments)
    else
      _ -> {:error, %{reason: "You cannot upload to this ticket."}, socket}
    end
  end

  def cancel(socket) do
    Enum.reduce(socket.assigns.uploads.message_attachments.entries, socket, fn entry, socket ->
      cancel_upload(socket, :message_attachments, entry.ref)
    end)
  end

  def submit(socket, form, params) do
    {entries, pending} = uploaded_entries(socket, :message_attachments)

    if pending != [] or
         Phoenix.Component.upload_errors(socket.assigns.uploads.message_attachments) != [] do
      {:error, :uploads_pending}
    else
      result =
        Helpdesk.Repo.transaction(fn ->
          case AshPhoenix.Form.submit(form, params: params) do
            {:ok, message} ->
              TicketUploads.persist_message!(message, entries, socket.assigns.current_user)
              message

            {:error, form} ->
              Helpdesk.Repo.rollback({:form, form})
          end
        end)

      case result do
        {:ok, message} ->
          TicketUploads.consume(socket, :message_attachments)
          {:ok, message}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  def error_message(:uploads_pending),
    do: "Please finish or remove failed uploads before sending."

  def error_message(:attachment_failed),
    do: "Attachments could not be saved. Your message was not sent. Please try again."
end
