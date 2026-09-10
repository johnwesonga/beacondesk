defmodule Helpdesk.Notifications do
  @moduledoc """
  Durable in-app notifications with authorized list, count and read actions.
  Ordinary application actors cannot access the internal outbox.
  """
  use Ash.Domain, otp_app: :helpdesk
  require Ash.Query
  alias Helpdesk.Notifications.Notification

  resources do
    resource Helpdesk.Notifications.OutboxEvent
    resource Helpdesk.Notifications.Notification
  end

  def list_notifications(actor, opts \\ []) do
    Notification
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> then(fn query ->
      if Keyword.get(opts, :unread?, false),
        do: Ash.Query.filter(query, is_nil(read_at)),
        else: query
    end)
    |> Ash.read(actor: actor, page: Keyword.get(opts, :page, limit: 20))
  end

  def unread_count(actor) do
    Notification |> Ash.Query.filter(is_nil(read_at)) |> Ash.count(actor: actor)
  end

  def mark_read(actor, id) do
    with {:ok, notification} <- Ash.get(Notification, id, actor: actor) do
      Ash.update(notification, %{}, action: :mark_read, actor: actor)
    end
  end
end
