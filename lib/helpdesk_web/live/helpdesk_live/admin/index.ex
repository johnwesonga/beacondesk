defmodule HelpdeskWeb.HelpdeskLive.Admin.Index do
  use HelpdeskWeb, :live_view
  alias Helpdesk.Notifications.Operations, as: NotificationOperations
  alias Helpdesk.Reporting.Operations, as: ReportingOperations
  on_mount {HelpdeskWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    case load_reports(socket.assigns.current_user) do
      {:ok, report, notification_queues} ->
        {:ok,
         socket
         |> assign(:current_scope, %{user: socket.assigns.current_user})
         |> assign(:page_title, "Support operations")
         |> assign(:notification_queues, notification_queues)
         |> assign_report(report)}

      {:error, :forbidden} ->
        {:ok,
         socket
         |> put_flash(:error, "You do not have access to support operations.")
         |> redirect(to: ~p"/tickets")}
    end
  end

  @impl true
  def handle_event("refresh", _, socket) do
    # Reload the actor so revoked access cannot continue to read reports.
    actor = Helpdesk.Repo.get(Helpdesk.Accounts.User, socket.assigns.current_user.id)

    case load_reports(actor) do
      {:ok, report, notification_queues} ->
        {:noreply,
         socket
         |> assign(:notification_queues, notification_queues)
         |> assign_report(report)}

      {:error, :forbidden} ->
        {:noreply, redirect(socket, to: ~p"/tickets")}
    end
  end

  defp load_reports(actor) do
    with {:ok, report} <- ReportingOperations.load(actor),
         {:ok, notification_queues} <- NotificationOperations.status(actor) do
      {:ok, report, notification_queues}
    end
  end

  defp assign_report(socket, report) do
    socket
    |> assign(:report, Map.drop(report, [:queues, :volume]))
    |> stream(:volume, report.volume, reset: true)
    |> stream(:queues, report.queues, reset: true)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      notification_count={@notification_count}
      flash={@flash}
      current_scope={@current_scope}
      current_page={:operations}
    >
      <section id="admin-dashboard">
        <div class="mb-7 flex flex-wrap items-end justify-between gap-4">
          <div>
            <p class="text-sm font-semibold text-violet-600">Administration</p>
            <h1 class="mt-1 text-3xl font-black tracking-tight text-slate-900">Support operations</h1>
            <p class="mt-2 text-sm text-slate-500">
              Team performance and workload for the last 30 days.
            </p>
          </div>
          <button
            id="refresh-operations"
            phx-click="refresh"
            phx-disable-with="Refreshing…"
            class="flex items-center gap-2 rounded-lg border border-slate-200 bg-white px-3 py-2 text-sm font-semibold hover:bg-slate-100"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Refresh
          </button>
        </div>
        <div class="grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
          <.metric
            id="tickets-created"
            label="Tickets created"
            value={@report.created}
            detail={comparison(@report.created, @report.previous_created)}
          />
          <.metric
            id="first-reply"
            label="Median first reply"
            value={duration(@report.first_reply)}
            detail="First public staff reply · new tickets"
          />
          <.metric
            id="resolution-time"
            label="Median resolution time"
            value={duration(@report.resolution)}
            detail="Created to latest resolution · new tickets"
          />
          <.metric id="satisfaction" label="Satisfaction" value="—" detail="Not collected yet" />
        </div>
        <section
          id="notification-queue-health"
          aria-labelledby="notification-queue-heading"
          class="mt-6 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"
        >
          <div class="flex flex-wrap items-start justify-between gap-4">
            <div>
              <h2 id="notification-queue-heading" class="font-black">Notification processing</h2>
              <p class="mt-1 text-sm text-slate-500">
                Durable outbox health and email delivery status
              </p>
            </div>
            <.link
              id="open-oban-dashboard"
              href="/admin/oban"
              class="rounded-lg border border-slate-300 px-3 py-2 text-sm font-semibold hover:bg-slate-50"
            >
              Open job dashboard
            </.link>
          </div>
          <div class="mt-5 grid gap-4 sm:grid-cols-2 xl:grid-cols-4">
            <.queue_metric
              id="outbox-pending"
              label="Outbox pending"
              value={Map.get(@notification_queues.outbox, :pending, 0)}
            />
            <.queue_metric
              id="outbox-failed"
              label="Outbox failed"
              value={Map.get(@notification_queues.outbox, :failed, 0)}
            />
            <.queue_metric
              id="outbox-overdue"
              label="Outbox overdue"
              value={@notification_queues.overdue_outbox}
            />
            <.queue_metric
              id="outbox-oldest"
              label="Oldest pending"
              value={pending_age(@notification_queues.oldest_pending_outbox)}
            />
          </div>
        </section>
        <div class="mt-6 grid gap-6 xl:grid-cols-[1.5fr_1fr]">
          <section
            aria-labelledby="volume-heading"
            class="min-w-0 rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"
          >
            <div class="flex flex-wrap items-center justify-between gap-3">
              <div>
                <h2 id="volume-heading" class="font-black">Ticket volume</h2>
                <p class="mt-1 text-sm text-slate-500">Created and resolved in six-day intervals</p>
              </div>
              <span class="rounded-lg border border-slate-200 px-3 py-2 text-xs text-slate-500">
                Last 30 days
              </span>
            </div>
            <div
              id="ticket-volume"
              phx-update="stream"
              class="mt-8 flex h-64 gap-2 border-b border-slate-200"
            >
              <div :for={{id, bucket} <- @streams.volume} id={id} class="flex min-w-0 flex-1 flex-col">
                <div class="flex flex-1 items-end justify-center gap-1" aria-hidden="true">
                  <div
                    class="w-4 rounded-t bg-sky-500 sm:w-6"
                    style={"height: #{bucket.created / @report.chart_max * 100}%"}
                    title={"#{bucket.created} created"}
                  >
                  </div>
                  <div
                    class="w-4 rounded-t bg-slate-300 sm:w-6"
                    style={"height: #{bucket.resolved / @report.chart_max * 100}%"}
                    title={"#{bucket.resolved} resolved"}
                  >
                  </div>
                </div>
                <p class="border-t border-slate-100 py-3 text-center text-[10px] text-slate-500 sm:text-xs">
                  {bucket.label}
                </p>
                <p class="sr-only">
                  Starting {bucket.label}: {bucket.created} created, {bucket.resolved} resolved.
                </p>
              </div>
            </div>
            <div class="mt-4 flex justify-center gap-5 text-xs text-slate-500">
              <span class="flex items-center gap-2">
                <span class="size-2 rounded-full bg-sky-500"></span>Created
              </span>
              <span class="flex items-center gap-2">
                <span class="size-2 rounded-full bg-slate-300"></span>Resolved
              </span>
            </div>
            <p class="mt-4 text-xs leading-5 text-slate-500">
              Resolution counts use the latest recorded resolution; reopened tickets without a resolution date are excluded.
            </p>
          </section>
          <section
            aria-labelledby="queue-heading"
            class="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm"
          >
            <h2 id="queue-heading" class="font-black">Queue health</h2>
            <p class="mt-1 text-sm text-slate-500">
              Current open workload by team · {@report.open_count} tickets
            </p>
            <div
              id="team-workload"
              phx-update="stream"
              class="mt-6 max-h-80 space-y-5 overflow-y-auto"
            >
              <div :for={{id, queue} <- @streams.queues} id={id}>
                <div class="mb-2 flex justify-between gap-3 text-sm">
                  <span>
                    {queue.name}<span :if={!queue.active} class="ml-2 text-xs text-slate-400">Inactive</span>
                  </span>
                  <strong>{queue.count}</strong>
                </div>
                <progress
                  aria-label={"#{queue.name}: #{queue.count} open tickets"}
                  class="h-2 w-full overflow-hidden rounded-full [&::-webkit-progress-bar]:bg-slate-100 [&::-webkit-progress-value]:bg-sky-500 [&::-moz-progress-bar]:bg-sky-500"
                  value={queue.count}
                  max={max(@report.open_count, 1)}
                >
                  {queue.count}
                </progress>
              </div>
            </div>
            <p :if={@report.open_count == 0} id="queues-empty" class="mt-4 text-sm text-slate-500">
              No open tickets. Your queues are clear.
            </p>
            <.link
              id="manage-teams"
              navigate={~p"/teams"}
              class="mt-7 block rounded-lg border border-slate-300 px-3 py-2 text-center text-sm font-semibold hover:bg-slate-50"
            >
              Manage teams
            </.link>
          </section>
        </div>
        <p class="mt-5 text-xs text-slate-500">
          Updated {Calendar.strftime(@report.as_of, "%b %d, %Y at %H:%M UTC")}. Refresh to include new activity.
        </p>
      </section>
    </Layouts.app>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true
  attr :detail, :string, required: true

  defp metric(assigns) do
    ~H"""
    <div id={@id} class="rounded-2xl border border-slate-200 bg-white p-5 shadow-sm">
      <p class="text-sm text-slate-500">{@label}</p>
      <p class="mt-2 text-3xl font-black tracking-tight text-slate-900">{@value}</p>
      <p class="mt-2 text-xs leading-5 text-slate-500">{@detail}</p>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, required: true

  defp queue_metric(assigns) do
    ~H"""
    <div id={@id} class="rounded-xl bg-slate-50 p-4">
      <p class="text-xs font-semibold uppercase tracking-wide text-slate-500">{@label}</p>
      <p class="mt-2 text-2xl font-black text-slate-900">{@value}</p>
    </div>
    """
  end

  defp pending_age(nil), do: "—"

  defp pending_age(datetime) do
    seconds = max(DateTime.diff(DateTime.utc_now(), datetime, :second), 0)

    cond do
      seconds < 60 -> "< 1m"
      seconds < 3_600 -> "#{div(seconds, 60)}m"
      seconds < 86_400 -> "#{div(seconds, 3_600)}h"
      true -> "#{div(seconds, 86_400)}d"
    end
  end

  defp duration(nil), do: "—"
  defp duration(seconds) when seconds < 60, do: "< 1m"
  defp duration(seconds) when seconds < 3600, do: "#{round(seconds / 60)}m"
  defp duration(seconds) when seconds < 86_400, do: "#{Float.round(seconds / 3600, 1)}h"
  defp duration(seconds), do: "#{Float.round(seconds / 86_400, 1)}d"

  defp comparison(_, 0), do: "No comparison data in the previous 30 days"

  defp comparison(current, previous) do
    change = Float.round((current - previous) / previous * 100, 1)
    "#{if change > 0, do: "+", else: ""}#{change}% vs previous 30 days"
  end
end
