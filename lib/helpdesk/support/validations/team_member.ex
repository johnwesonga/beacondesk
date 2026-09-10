defmodule Helpdesk.Support.Validations.TeamMember do
  use Ash.Resource.Validation
  import Ecto.Query
  alias Helpdesk.Repo
  alias Helpdesk.Support.{TeamMembership, Ticket}

  @impl true
  def validate(changeset, opts, _context) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    team_id = Ash.Changeset.get_attribute(changeset, :team_id)

    if opts[:removing?] do
      if Repo.exists?(
           from t in Ticket,
             where:
               t.team_id == ^team_id and t.assignee_id == ^user_id and
                 t.status not in [:resolved, :closed]
         ) do
        {:error,
         field: :user_id,
         message: "reassign this member's active tickets in this team before removing them"}
      else
        :ok
      end
    else
      user = user_id && Repo.get(Helpdesk.Accounts.User, user_id)

      cond do
        is_nil(team_id) or is_nil(Repo.get(Helpdesk.Support.Team, team_id)) ->
          {:error, field: :team_id, message: "team not found"}

        is_nil(user) or user.role not in [:admin, :agent] or user.status != :active ->
          {:error, field: :user_id, message: "select an active agent or administrator"}

        Repo.exists?(
          from m in TeamMembership, where: m.team_id == ^team_id and m.user_id == ^user_id
        ) ->
          {:error, field: :user_id, message: "already belongs to this team"}

        true ->
          :ok
      end
    end
  end
end
