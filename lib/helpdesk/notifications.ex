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
    |> Ash.Query.load(:ticket)
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
    with {:ok, notification} <- Ash.get(Notification, id, actor: actor),
         {:ok, updated} <- Ash.update(notification, %{}, action: :mark_read, actor: actor) do
      broadcast(actor)
      {:ok, updated}
    end
  end

  def mark_all_read(actor, cutoff \\ DateTime.utc_now()) do
    result = Helpdesk.Repo.transaction(fn -> mark_batch(actor, cutoff) end)
    if match?({:ok, _}, result), do: broadcast(actor)
    result
  end

  defp mark_batch(actor, cutoff) do
    page =
      Notification
      |> Ash.Query.filter(is_nil(read_at) and inserted_at <= ^cutoff)
      |> Ash.read!(actor: actor, page: [limit: 100])

    Enum.each(page.results, fn notification ->
      case Ash.update(notification, %{}, action: :mark_read, actor: actor) do
        {:ok, _} -> :ok
        {:error, error} -> Helpdesk.Repo.rollback(error)
      end
    end)

    if page.more?, do: mark_batch(actor, cutoff), else: :ok
  end

  defp broadcast(actor) do
    Phoenix.PubSub.broadcast(
      Helpdesk.PubSub,
      "notifications:user:#{actor.id}",
      :notifications_changed
    )
  end
end
