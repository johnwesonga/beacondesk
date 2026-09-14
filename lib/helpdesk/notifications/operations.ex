defmodule Helpdesk.Notifications.Operations do
  @moduledoc "Administrator-only queue inspection and controlled retries."
  import Ecto.Query
  alias Helpdesk.Repo
  alias Helpdesk.Notifications.{Delivery, OutboxEvent}

  def status(actor) do
    with :ok <- authorize(actor) do
      now = DateTime.utc_now()

      {:ok,
       %{
         outbox: counts(OutboxEvent),
         email: counts(Delivery),
         oldest_pending_outbox: oldest_pending(OutboxEvent),
         oldest_pending_email: oldest_pending(Delivery),
         overdue_outbox:
           Repo.one(
             from e in OutboxEvent,
               where: e.status == :pending and e.next_attempt_at <= ^now,
               select: count(e.id)
           )
       }}
    end
  end

  def retry_failed(actor, :email, id) do
    with :ok <- authorize(actor), {:ok, id} <- Ash.Type.cast_input(:uuid, id) do
      {count, _} =
        Repo.update_all(from(e in Delivery, where: e.id == ^id and e.status == :failed),
          set: [
            status: :pending,
            attempts: 0,
            next_attempt_at: DateTime.utc_now(),
            lease_token: nil,
            lease_expires_at: nil,
            last_error_code: nil,
            updated_at: DateTime.utc_now()
          ]
        )

      {:ok, count}
    end
  end

  def retry_failed(actor, :outbox, id) do
    with :ok <- authorize(actor),
         {:ok, id} <- Ash.Type.cast_input(:uuid, id) do
      retry_outbox(id)
    end
  end

  defp retry_outbox(id) do
    try do
      Repo.transaction(fn ->
        now = DateTime.utc_now()

        {count, _} =
          Repo.update_all(from(e in OutboxEvent, where: e.id == ^id and e.status == :failed),
            set: [
              status: :pending,
              attempts: 0,
              next_attempt_at: now,
              lease_token: nil,
              lease_expires_at: nil,
              processed_at: nil,
              last_error_code: nil,
              updated_at: now
            ]
          )

        if count == 1 and Helpdesk.Notifications.ProcessingMode.ash_oban?() do
          event = Repo.get!(OutboxEvent, id)

          AshOban.run_trigger(event, :process_notification_event,
            args: %{retry_nonce: Ash.UUID.generate()}
          )
        end

        count
      end)
      |> case do
        {:ok, count} -> {:ok, count}
        {:error, error} -> {:error, error}
      end
    rescue
      error -> {:error, error}
    end
  end

  defp counts(resource) do
    Repo.all(from e in resource, group_by: e.status, select: {e.status, count(e.id)}) |> Map.new()
  end

  defp oldest_pending(resource) do
    Repo.one(from e in resource, where: e.status == :pending, select: min(e.inserted_at))
  end

  defp authorize(%{id: id}) do
    case Repo.get(Helpdesk.Accounts.User, id) do
      %{role: :admin, status: :active} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp authorize(_), do: {:error, :forbidden}
end
