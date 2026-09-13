defmodule Helpdesk.Notifications.Changes.ProcessOutboxEvent do
  @moduledoc false

  use Ash.Resource.Change

  alias Helpdesk.Notifications.Fanout
  alias Helpdesk.Repo

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.around_action(changeset, fn changeset, callback ->
      try do
        Repo.transaction(fn ->
          case callback.(changeset) do
            {:ok, event, _completed_changeset, _instructions} = result ->
              {result, Fanout.deliver(event)}

            {:error, error} ->
              Repo.rollback(error)
          end
        end)
        |> case do
          {:ok, {result, recipients}} ->
            Enum.each(recipients, &broadcast/1)
            result

          {:error, error} ->
            {:error, error}
        end
      rescue
        error -> {:error, error}
      end
    end)
  end

  defp broadcast(recipient_id) do
    Phoenix.PubSub.broadcast(
      Helpdesk.PubSub,
      "notifications:user:#{recipient_id}",
      :notifications_changed
    )
  end
end
