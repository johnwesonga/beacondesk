defmodule Helpdesk.Support.Changes.SetStatusTimestamps do
  @moduledoc """
  Maintains resolution and closure timestamps when a ticket changes status.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.fetch_change(changeset, :status) do
      {:ok, status} when status != changeset.data.status ->
        set_timestamps(changeset, status, DateTime.utc_now())

      _ ->
        changeset
    end
  end

  defp set_timestamps(changeset, :resolved, now) do
    changeset
    |> Ash.Changeset.force_change_attribute(:resolved_at, now)
    |> Ash.Changeset.force_change_attribute(:closed_at, nil)
  end

  defp set_timestamps(changeset, :closed, now) do
    Ash.Changeset.force_change_attribute(changeset, :closed_at, now)
  end

  defp set_timestamps(changeset, _active_status, _now) do
    changeset
    |> Ash.Changeset.force_change_attribute(:resolved_at, nil)
    |> Ash.Changeset.force_change_attribute(:closed_at, nil)
  end
end
