defmodule Helpdesk.Notifications.Worker do
  @moduledoc "Processes committed outbox rows into in-app notifications."
  use GenServer
  import Ecto.Query
  require Logger
  alias Helpdesk.Notifications.{Fanout, OutboxEvent}
  alias Helpdesk.Repo

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if Application.get_env(:helpdesk, :notification_worker_enabled, true), do: schedule()
    {:ok, nil}
  end

  @impl true
  def handle_info(:poll, state) do
    try do
      run_once()
    rescue
      _ -> Logger.warning("Notification poll failed; will retry on next poll")
    after
      schedule()
    end

    {:noreply, state}
  end

  defp schedule do
    Process.send_after(
      self(),
      :poll,
      Application.get_env(:helpdesk, :notification_poll_interval, 5_000)
    )
  end

  @doc "Process a bounded batch synchronously; tests may pass a controlled UTC time."
  def run_once(now \\ DateTime.utc_now()) do
    unless Repo.in_transaction?() do
      ids =
        Repo.all(
          from e in OutboxEvent,
            where: e.status == :pending and e.next_attempt_at <= ^now,
            order_by: [asc: e.next_attempt_at, asc: e.id],
            limit: 25,
            select: e.id
        )

      Enum.map(ids, &process(&1, now))
    else
      raise ArgumentError, "notification processing must run outside a parent transaction"
    end
  end

  defp process(id, now) do
    # Claim and fan-out share one short SQLite writer transaction. A crash rolls
    # back both: no network I/O or persisted lease is needed for in-app delivery.
    result =
      Repo.transaction(fn ->
        query =
          from e in OutboxEvent,
            where: e.id == ^id and e.status == :pending and e.next_attempt_at <= ^now

        case Repo.update_all(query, set: [status: :processing, updated_at: now]) do
          {0, _} ->
            []

          {1, _} ->
            event = Repo.get!(OutboxEvent, id)

            delivered = Fanout.deliver(event)

            Repo.update_all(from(e in OutboxEvent, where: e.id == ^id),
              set: [status: :processed, processed_at: now, updated_at: now, last_error_code: nil],
              inc: [attempts: 1]
            )

            delivered
        end
      end)

    case result do
      {:ok, recipients} ->
        Enum.each(recipients, fn id ->
          Phoenix.PubSub.broadcast(
            Helpdesk.PubSub,
            "notifications:user:#{id}",
            :notifications_changed
          )
        end)

        {:ok, id}

      {:error, _} ->
        retry(id, now)
    end
  rescue
    _ -> retry(id, now)
  end

  defp retry(id, now) do
    event = Repo.get!(OutboxEvent, id)
    attempts = event.attempts + 1
    delay = min(30 * Integer.pow(2, min(attempts - 1, 7)), 3600)
    next_attempt = DateTime.add(now, delay + :rand.uniform(max(div(delay, 5), 1)), :second)

    Repo.update_all(
      from(e in OutboxEvent,
        where: e.id == ^id and e.status == :pending and e.attempts == ^event.attempts
      ),
      set: [
        attempts: attempts,
        status: if(attempts >= 8, do: :failed, else: :pending),
        next_attempt_at: next_attempt,
        last_error_code: "processing_failed",
        updated_at: now
      ]
    )

    {:error, id}
  end
end
