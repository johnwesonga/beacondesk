defmodule HelpdeskWeb.NotificationsLive do
  use HelpdeskWeb, :live_view
  on_mount {HelpdeskWeb.LiveUserAuth, :live_user_required}
  alias Helpdesk.Notifications

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       current_scope: %{user: socket.assigns.current_user},
       page_title: "Notifications",
       unread?: false,
       cursors: [nil],
       more?: false,
       next_cursor: nil
     )
     |> load_notifications()
     |> load_preferences()}
  end

  @impl true
  def handle_info(:refresh_notification_state, socket) do
    {:noreply, load_notifications(socket)}
  end

  @impl true
  def handle_event("save_preferences", %{"preferences" => params}, socket) do
    case Notifications.set_email_preferences(socket.assigns.current_user, params) do
      {:ok, _} ->
        {:noreply, socket |> load_preferences() |> put_flash(:info, "Email preferences saved.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save email preferences.")}
    end
  end

  def handle_event("filter", %{"filter" => filter}, socket) when filter in ["all", "unread"] do
    {:noreply,
     socket |> assign(unread?: filter == "unread", cursors: [nil]) |> load_notifications()}
  end

  def handle_event("next", _, %{assigns: %{more?: true}} = socket) do
    {:noreply,
     socket
     |> assign(:cursors, [socket.assigns.next_cursor | socket.assigns.cursors])
     |> load_notifications()}
  end

  def handle_event("previous", _, %{assigns: %{cursors: [_, _ | _]}} = socket) do
    {:noreply, socket |> assign(:cursors, tl(socket.assigns.cursors)) |> load_notifications()}
  end

  def handle_event(event, _, socket) when event in ["next", "previous"], do: {:noreply, socket}

  def handle_event("mark_all", _, socket) do
    case Notifications.mark_all_read(socket.assigns.current_user) do
      {:ok, _} ->
        {:noreply, socket |> assign(:cursors, [nil]) |> refresh()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not mark notifications as read.")}
    end
  end

  def handle_event(event, %{"id" => id}, socket) when event in ["read", "open"] do
    case Notifications.mark_read(socket.assigns.current_user, id) do
      {:ok, notification} when event == "open" ->
        {:noreply, push_navigate(socket, to: ~p"/tickets/#{notification.ticket_id}")}

      {:ok, _} ->
        {:noreply, refresh(socket)}

      {:error, _} ->
        {:noreply,
         socket |> put_flash(:error, "This notification is no longer available.") |> refresh()}
    end
  end

  defp load_preferences(socket) do
    case Notifications.email_preferences(socket.assigns.current_user) do
      {:ok, values} ->
        assign(socket,
          preference_form: to_form(values, as: :preferences),
          email_kinds: Helpdesk.Notifications.Email.kinds()
        )

      {:error, _} ->
        assign(socket, preference_form: nil, email_kinds: [])
    end
  end

  defp refresh(socket),
    do: socket |> HelpdeskWeb.NotificationState.refresh() |> load_notifications()

  defp load_notifications(socket) do
    [cursor | _] = socket.assigns.cursors
    page_opts = if cursor, do: [limit: 20, after: cursor], else: [limit: 20]

    case Notifications.list_notifications(socket.assigns.current_user,
           unread?: socket.assigns.unread?,
           page: page_opts
         ) do
      {:ok, page} ->
        if page.results == [] and cursor do
          socket |> assign(:cursors, [nil]) |> load_notifications()
        else
          last = List.last(page.results)

          socket
          |> assign(
            more?: page.more?,
            next_cursor: last && last.__metadata__.keyset,
            empty?: page.results == [],
            load_error?: false
          )
          |> stream(:notifications, page.results, reset: true)
        end

      {:error, _} ->
        socket
        |> assign(empty?: true, more?: false, load_error?: true)
        |> stream(:notifications, [], reset: true)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_page={:notifications}
      notification_count={@notification_count}
    >
      <div class="mx-auto max-w-4xl space-y-6">
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div>
            <h1 class="text-2xl font-bold text-slate-900">Notifications</h1>
            <p class="mt-1 text-sm text-slate-500">Updates about your support tickets.</p>
          </div>
          <button
            id="mark-all-notifications-read"
            phx-click="mark_all"
            disabled={@notification_count in [nil, 0]}
            class="rounded-xl border border-slate-200 bg-white px-4 py-2 text-sm font-semibold disabled:opacity-50"
          >
            Mark all as read
          </button>
        </div>
        <div class="flex gap-2" aria-label="Notification filters">
          <button
            :for={{label, value} <- [{"All", "all"}, {"Unread", "unread"}]}
            id={"notifications-filter-#{value}"}
            phx-click="filter"
            phx-value-filter={value}
            aria-pressed={@unread? == (value == "unread")}
            class={[
              "rounded-xl px-4 py-2 text-sm font-semibold",
              if(@unread? == (value == "unread"),
                do: "bg-sky-600 text-white",
                else: "bg-white text-slate-600"
              )
            ]}
          >
            {label}
          </button>
        </div>
        <p :if={@load_error?} id="notifications-error" role="alert">
          Notifications could not be loaded. Please try again.
        </p>
        <p
          :if={@empty? and not @load_error?}
          id="notifications-empty"
          class="rounded-2xl border border-dashed border-slate-300 p-10 text-center text-slate-500"
        >
          {if @unread?, do: "You're all caught up.", else: "No notifications yet."}
        </p>
        <div id="notification-list" phx-update="stream" class="space-y-3">
          <article
            :for={{dom_id, notification} <- @streams.notifications}
            id={dom_id}
            class={[
              "flex flex-wrap items-center justify-between gap-3 rounded-2xl border p-4",
              if(is_nil(notification.read_at),
                do: "border-sky-200 bg-sky-50",
                else: "border-slate-200 bg-white"
              )
            ]}
          >
            <button
              id={"open-#{notification.id}"}
              phx-click="open"
              phx-value-id={notification.id}
              class="min-w-0 text-left"
            >
              <span class="block font-semibold text-slate-900">{label(notification.kind)}</span>
              <span class="block text-sm text-slate-600">
                {notification.ticket.ticket_number} · {notification.ticket.title}
              </span>
              <time
                datetime={DateTime.to_iso8601(notification.inserted_at)}
                class="mt-1 block text-xs text-slate-500"
              >
                {Calendar.strftime(notification.inserted_at, "%d %b %Y, %H:%M UTC")}
              </time>
            </button>
            <button
              :if={is_nil(notification.read_at)}
              id={"read-#{notification.id}"}
              phx-click="read"
              phx-value-id={notification.id}
              class="rounded-lg px-3 py-2 text-sm font-semibold text-sky-700 hover:bg-sky-100"
            >
              Mark as read
            </button>
          </article>
        </div>
        <nav aria-label="Notification pages" class="flex justify-between">
          <button
            id="notifications-previous"
            phx-click="previous"
            disabled={length(@cursors) == 1}
            class="rounded-lg border px-4 py-2 disabled:opacity-40"
          >
            Previous
          </button>
          <button
            id="notifications-next"
            phx-click="next"
            disabled={not @more?}
            class="rounded-lg border px-4 py-2 disabled:opacity-40"
          >
            Next
          </button>
        </nav>
        <details :if={@preference_form} class="rounded-2xl border border-slate-200 bg-white p-5">
          <summary class="cursor-pointer font-semibold">Email preferences</summary>
          <p class="my-3 text-sm text-slate-500">
            Choose email updates for tickets you report or are assigned to. In-app notifications remain enabled. Account confirmation and password reset emails are unaffected.
          </p>
          <.form for={@preference_form} id="notification-preferences" phx-submit="save_preferences">
            <.input
              :for={kind <- @email_kinds}
              field={@preference_form[kind]}
              type="checkbox"
              label={label(kind)}
            />
            <.button id="save-notification-preferences" type="submit">Save preferences</.button>
          </.form>
        </details>
      </div>
    </Layouts.app>
    """
  end

  defp label(kind) do
    Map.get(
      %{
        "ticket_created" => "New ticket",
        "assigned" => "Ticket assigned to you",
        "unassigned" => "Ticket needs an assignee",
        "team_changed" => "Ticket routed to your team",
        "public_reply" => "New reply",
        "internal_note" => "New internal note",
        "waiting_on_customer" => "Your response is needed",
        "resolved" => "Ticket resolved",
        "closed" => "Ticket closed",
        "reopened" => "Ticket reopened"
      },
      kind,
      "Ticket update"
    )
  end
end
