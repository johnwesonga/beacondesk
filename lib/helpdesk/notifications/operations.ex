defmodule Helpdesk.Notifications.Operations do
  @moduledoc "Administrator-only queue inspection and controlled retries."
  import Ecto.Query
  alias Helpdesk.Repo
  alias Helpdesk.Notifications.{Delivery, OutboxEvent}

  def status(actor) do
    with :ok <- authorize(actor) do
      {:ok,
       %{
         outbox: counts(OutboxEvent),
         email: counts(Delivery),
         oldest_pending_email:
           Repo.one(from d in Delivery, where: d.status == :pending, select: min(d.inserted_at))
       }}
    end
  end

  def retry_failed(actor, queue, id) when queue in [:email, :outbox] do
    with :ok <- authorize(actor), {:ok, id} <- Ash.Type.cast_input(:uuid, id) do
      resource = if queue == :email, do: Delivery, else: OutboxEvent

      {count, _} =
        Repo.update_all(from(e in resource, where: e.id == ^id and e.status == :failed),
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

  defp counts(resource) do
    Repo.all(from e in resource, group_by: e.status, select: {e.status, count(e.id)}) |> Map.new()
  end

  defp authorize(%{id: id}) do
    case Repo.get(Helpdesk.Accounts.User, id) do
      %{role: :admin, status: :active} -> :ok
      _ -> {:error, :forbidden}
    end
  end

  defp authorize(_), do: {:error, :forbidden}
end
