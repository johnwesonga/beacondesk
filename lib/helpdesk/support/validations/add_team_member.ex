defmodule Helpdesk.Support.Validations.AddTeamMember do
  use Ash.Resource.Validation
  import Ecto.Query
  alias Helpdesk.Accounts.User
  alias Helpdesk.Repo
  alias Helpdesk.Support.{Team, TeamMembership}

  @impl true
  def validate(changeset, _opts, _context) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    team_id = Ash.Changeset.get_attribute(changeset, :team_id)
    user = user_id && Repo.get(User, user_id)

    cond do
      is_nil(team_id) or is_nil(Repo.get(Team, team_id)) ->
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
