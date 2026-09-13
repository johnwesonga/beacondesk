defmodule Helpdesk.Notifications.Email do
  @moduledoc false
  import Swoosh.Email
  alias Helpdesk.Notifications.Preference
  alias Helpdesk.Repo

  def kinds,
    do: ~w(ticket_created assigned public_reply waiting_on_customer resolved closed reopened)

  def enabled?(user_id, kind) do
    kind in kinds() and
      case Repo.get_by(Preference, user_id: user_id, kind: kind) do
        nil -> true
        preference -> preference.email_enabled
      end
  end

  # Only direct owners/reporters receive email. Team fan-out remains in-app.
  def candidate?(event, recipient_id) do
    case Repo.get(Helpdesk.Support.Ticket, event.ticket_id) do
      nil ->
        false

      ticket ->
        case event.kind do
          kind when kind in [:ticket_created, :assigned] ->
            recipient_id == ticket.assignee_id

          :public_reply ->
            recipient_id in [ticket.reporter_id, ticket.assignee_id]

          :reopened ->
            recipient_id in [ticket.reporter_id, ticket.assignee_id]

          kind when kind in [:waiting_on_customer, :resolved, :closed] ->
            recipient_id == ticket.reporter_id

          _ ->
            false
        end
    end
  end

  def build(delivery, notification, user, ticket) do
    url = HelpdeskWeb.Endpoint.url() <> "/tickets/" <> ticket.id
    preferences_url = HelpdeskWeb.Endpoint.url() <> "/notifications"

    text =
      "There is an update to ticket #{ticket.ticket_number}.\n\nView ticket: #{url}\n\nEmail preferences: #{preferences_url}"

    escaped = text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    new()
    |> to(to_string(user.email))
    |> from({"BeaconDesk", Application.fetch_env!(:helpdesk, :notification_from)})
    |> subject("BeaconDesk ticket update")
    |> text_body(text)
    |> html_body("<p>" <> String.replace(escaped, "\n", "<br>") <> "</p>")
    |> put_provider_option(:idempotency_key, "notification-#{delivery.id}")
    |> header("X-Notification-ID", notification.id)
    |> put_private(:client_options, receive_timeout: 10_000, retry: false)
  end
end
