defmodule Helpdesk.Notifications.EmailWorker do
  @moduledoc "Leased email delivery outside SQLite transactions."
  use GenServer
  require Logger
  import Ecto.Query
  require Ash.Query
  alias Helpdesk.Repo
  alias Helpdesk.Accounts.User
  alias Helpdesk.Notifications.{Delivery, Notification, OutboxEvent, Email, Capture}

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
      _ -> Logger.warning("Notification email poll failed; will retry on next poll")
    after
      schedule()
    end

    {:noreply, state}
  end

  defp schedule do
    Process.send_after(
      self(),
      :poll,
      Application.get_env(:helpdesk, :notification_poll_interval, 60_000)
    )
  end

  def run_once(now \\ DateTime.utc_now()) do
    if Repo.in_transaction?(),
      do: raise(ArgumentError, "email delivery must run outside a transaction")

    if Application.get_env(:helpdesk, :notification_email_enabled, false) do
      ids =
        Repo.all(
          from d in Delivery,
            where:
              (d.status == :pending and d.next_attempt_at <= ^now) or
                (d.status == :sending and d.lease_expires_at <= ^now),
            order_by: [asc: d.next_attempt_at, asc: d.id],
            limit: 25,
            select: d.id
        )

      Enum.map(ids, &process(&1, now))
    else
      []
    end
  end

  defp process(id, now) do
    token = Ash.UUID.generate()

    query =
      from d in Delivery,
        where:
          d.id == ^id and
            ((d.status == :pending and d.next_attempt_at <= ^now) or
               (d.status == :sending and d.lease_expires_at <= ^now))

    case Repo.update_all(query,
           set: [
             status: :sending,
             lease_token: token,
             lease_expires_at: DateTime.add(now, 60, :second),
             updated_at: now
           ],
           inc: [attempts: 1]
         ) do
      {0, _} ->
        :not_claimed

      {1, _} ->
        delivery = Repo.get!(Delivery, id)

        result =
          if delivery.attempts > 8, do: {:error, :attempts_exhausted}, else: deliver(delivery)

        finish(delivery, token, result, now)
    end
  end

  defp deliver(delivery) do
    notification = Repo.get(Notification, delivery.notification_id)
    user = notification && Repo.get(User, notification.recipient_id)
    event = notification && Repo.get(OutboxEvent, notification.outbox_event_id)

    cond do
      is_nil(notification) or is_nil(event) ->
        {:skip, "missing_target"}

      is_nil(user) or user.status != :active ->
        {:skip, "inactive_recipient"}

      is_nil(user.confirmed_at) ->
        {:skip, "unconfirmed_email"}

      not Email.enabled?(user.id, notification.kind) ->
        {:skip, "preference_disabled"}

      not Capture.current_candidate?(event, user.id) or not Email.candidate?(event, user.id) ->
        {:skip, "routing_changed"}

      not (Notification
           |> Ash.Query.filter(id == ^notification.id)
           |> Ash.exists?(actor: user)) ->
        {:skip, "access_revoked"}

      true ->
        ticket = Repo.get!(Helpdesk.Support.Ticket, notification.ticket_id)
        email = Email.build(delivery, notification, user, ticket)
        # Bound provider execution below the lease lifetime, including adapters
        # without transport timeouts. The task is supervised and not linked here.
        task =
          Task.Supervisor.async_nolink(Helpdesk.NotificationTasks, fn ->
            Helpdesk.Mailer.deliver(email)
          end)

        case Task.yield(task, 15_000) || Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _ -> {:error, :provider_timeout}
        end
    end
  rescue
    _ -> {:error, :processing_failed}
  end

  defp finish(delivery, token, result, now) do
    {status, code, provider_id} =
      case result do
        {:ok, response} ->
          {:sent, nil,
           if(is_map(response), do: Map.get(response, :id) || Map.get(response, "id"))}

        {:skip, reason} ->
          {:skipped, reason, nil}

        {:error, {409, %{"name" => "invalid_idempotent_request"}}} ->
          {:failed, "idempotency_conflict", nil}

        {:error, {status, _}} when status in 400..499 and status not in [408, 409, 429] ->
          {:failed, "provider_#{status}", nil}

        _ ->
          {if(delivery.attempts >= 8, do: :failed, else: :pending), "delivery_failed", nil}
      end

    delay = min(30 * Integer.pow(2, min(delivery.attempts - 1, 7)), 3600)
    retry_at = DateTime.add(now, delay + :rand.uniform(max(div(delay, 5), 1)), :second)

    {count, _} =
      Repo.update_all(
        from(d in Delivery,
          where:
            d.id == ^delivery.id and
              d.status == :sending and d.lease_token == ^token
        ),
        set: [
          status: status,
          last_error_code: code,
          provider_message_id: provider_id,
          sent_at: if(status == :sent, do: now),
          next_attempt_at: retry_at,
          lease_token: nil,
          lease_expires_at: nil,
          updated_at: now
        ]
      )

    if count == 1 do
      :telemetry.execute([:helpdesk, :notifications, :email, :delivery], %{count: 1}, %{
        status: status,
        delivery_id: delivery.id
      })
    end

    {status, delivery.id}
  end
end
