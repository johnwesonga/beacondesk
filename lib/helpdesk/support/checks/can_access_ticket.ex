defmodule Helpdesk.Support.Checks.CanAccessTicket do
  @moduledoc "Checks access to a message's target ticket before inserting the message."

  use Ash.Policy.SimpleCheck
  require Ash.Query
  alias Helpdesk.Support.Ticket

  @impl true
  def describe(_opts), do: "actor can access the target ticket"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{changeset: %Ash.Changeset{} = changeset}, opts) do
    ticket_id = Ash.Changeset.get_attribute(changeset, :ticket_id)

    if is_nil(ticket_id) do
      false
    else
      query = Ash.Query.filter(Ticket, id == ^ticket_id)

      query =
        if Keyword.get(opts, :staff_only?, false) and actor.role != :admin do
          Ash.Query.filter(
            query,
            ^actor.role == :agent and
              (assignee_id == ^actor.id or exists(team.members, user_id == ^actor.id))
          )
        else
          query
        end

      Ash.exists(query, actor: actor, authorize?: true)
    end
  end

  def match?(_actor, _context, _opts), do: false
end
