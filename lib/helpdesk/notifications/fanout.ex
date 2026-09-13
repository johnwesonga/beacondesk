defmodule Helpdesk.Notifications.Fanout do
  @moduledoc """
  Builds the durable in-app and email-delivery records for one outbox event.

  Recipient eligibility is deliberately recalculated at processing time. The
  unique identities on notifications and deliveries make repeated fan-out
  safe.
  """

  require Ash.Query

  alias Helpdesk.Accounts.User
  alias Helpdesk.Notifications.{Delivery, Notification}
  alias Helpdesk.Repo
  alias Helpdesk.Support.Message

  @doc "Returns the IDs of recipients that received a visible notification."
  def deliver(event) do
    event.candidate_recipient_ids
    |> Enum.uniq()
    |> Enum.reject(&(&1 == event.actor_id))
    |> Enum.filter(fn recipient_id ->
      Helpdesk.Notifications.Capture.current_candidate?(event, recipient_id) and
        message_exists?(event) and deliver_to(event, recipient_id)
    end)
  end

  defp message_exists?(%{message_id: nil}), do: true
  defp message_exists?(event), do: not is_nil(Repo.get(Message, event.message_id))

  defp deliver_to(event, recipient_id) do
    case Repo.get(User, recipient_id) do
      %User{status: :active} = actor ->
        notification = upsert_notification(event, recipient_id)

        if visible?(notification, actor) do
          maybe_enqueue_email(event, notification)
          true
        else
          Repo.delete!(notification)
          false
        end

      _ ->
        false
    end
  end

  defp upsert_notification(event, recipient_id) do
    Ash.create!(
      Notification,
      %{
        outbox_event_id: event.id,
        recipient_id: recipient_id,
        ticket_id: event.ticket_id,
        message_id: event.message_id,
        kind: Atom.to_string(event.kind)
      },
      action: :deliver,
      authorize?: false,
      upsert?: true,
      upsert_identity: :unique_event_recipient,
      upsert_fields: []
    )
  end

  defp visible?(notification, actor) do
    Notification
    |> Ash.Query.filter(id == ^notification.id)
    |> Ash.exists?(actor: actor)
  end

  defp maybe_enqueue_email(event, notification) do
    if Application.get_env(:helpdesk, :notification_email_enabled, false) and
         notification.recipient_id in Map.get(event.payload, "email_recipient_ids", []) and
         Helpdesk.Notifications.Email.enabled?(notification.recipient_id, notification.kind) do
      Ash.create!(Delivery, %{notification_id: notification.id},
        action: :enqueue,
        authorize?: false,
        upsert?: true,
        upsert_identity: :unique_notification_channel,
        upsert_fields: []
      )
    end
  end
end
