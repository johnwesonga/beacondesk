defmodule HelpdeskWeb.NotificationState do
  @moduledoc false
  import Phoenix.Component
  import Phoenix.LiveView

  def mount(socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(
        Helpdesk.PubSub,
        "notifications:user:#{socket.assigns.current_user.id}"
      )
    end

    socket
    |> refresh()
    |> assign(:notification_refresh_pending, false)
    |> attach_hook(:notifications, :handle_info, &handle_info/2)
  end

  def refresh(socket) do
    case Helpdesk.Notifications.unread_count(socket.assigns.current_user) do
      {:ok, count} -> assign(socket, :notification_count, count)
      {:error, _} -> assign(socket, :notification_count, nil)
    end
  end

  defp handle_info(:notifications_changed, socket) do
    unless socket.assigns.notification_refresh_pending do
      Process.send_after(self(), :refresh_notification_state, 50)
    end

    {:halt, assign(socket, :notification_refresh_pending, true)}
  end

  defp handle_info(:refresh_notification_state, socket) do
    socket = socket |> refresh() |> assign(:notification_refresh_pending, false)

    if socket.view == HelpdeskWeb.NotificationsLive do
      {:cont, socket}
    else
      {:halt, socket}
    end
  end

  defp handle_info(_, socket), do: {:cont, socket}
end
