defmodule HelpdeskWeb.AttachmentController do
  use HelpdeskWeb, :controller

  def download(conn, %{"id" => id}) do
    actor = conn.assigns[:current_user]

    if Helpdesk.Accounts.Authorization.allowed?(actor, :read_tickets) do
      case Ash.get(Helpdesk.Support.Attachment, id, actor: actor) do
        {:ok, attachment} when not is_nil(attachment) ->
          redirect(conn, external: Helpdesk.AttachmentStore.presigned_download_url(attachment))

        _ ->
          send_resp(conn, 404, "Attachment not found")
      end
    else
      redirect(conn, to: ~p"/sign-in")
    end
  end
end
