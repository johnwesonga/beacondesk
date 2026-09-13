defmodule Helpdesk.Notifications.Changes.RecordOutboxFailure do
  @moduledoc false

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_transaction(changeset, fn _changeset, result ->
      case result do
        {:ok, event} ->
          :telemetry.execute(
            [:helpdesk, :notifications, :outbox, :processing_failed],
            %{count: 1},
            %{kind: event.kind, error_code: event.last_error_code}
          )

        _error ->
          :ok
      end

      result
    end)
  end
end
