defmodule Helpdesk.Support.Validations.RemoveTeamMember do
  use Ash.Resource.Validation
  require Ash.Query
  alias Helpdesk.Support.Ticket

  @impl true
  def validate(changeset, _opts, _context) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    team_id = Ash.Changeset.get_attribute(changeset, :team_id)

    # This integrity check must include assignments outside the actor's read scope.
    active_tickets? =
      Ticket
      |> Ash.Query.filter(
        team_id == ^team_id and assignee_id == ^user_id and status not in [:resolved, :closed]
      )
      |> Ash.exists?(authorize?: false)

    if active_tickets? do
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :user_id,
         value: user_id,
         message: "reassign this member's active tickets in this team before removing them"
       )}
    else
      :ok
    end
  end
end
