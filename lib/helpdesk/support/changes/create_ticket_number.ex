defmodule Helpdesk.Support.Changes.CreateTicketNumber do
  @moduledoc "Generates a server-side ticket reference using 80 bits of randomness."

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    suffix = :crypto.strong_rand_bytes(10) |> Base.encode32(padding: false)

    Ash.Changeset.force_change_attribute(changeset, :ticket_number, "TKT-" <> suffix)
  end
end
