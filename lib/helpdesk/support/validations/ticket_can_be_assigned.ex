defmodule Helpdesk.Support.Validations.TicketCanBeAssigned do
  @moduledoc """
  Validates that:
  1) a ticket can be assigned to a user of the correct role, admin or agent.
  2) The selected team is active
  3) Assignee belongs to the selected team.
  """

  use Ash.Resource.Validation

  alias Helpdesk.Accounts.User
  alias Helpdesk.Repo
  alias Helpdesk.Support.Team
  alias Helpdesk.Support.TeamMembership
  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    if assignment_changed?(changeset) or changeset.action.name == :assign do
      assignee_id = Ash.Changeset.get_attribute(changeset, :assignee_id)
      team_id = Ash.Changeset.get_attribute(changeset, :team_id)

      with :ok <- validate_assignee_role(assignee_id),
           :ok <- validate_team_active(team_id) do
        validate_team_membership_assignee(assignee_id, team_id)
      end
    else
      :ok
    end
  end

  defp validate_assignee_role(nil), do: :ok

  defp validate_assignee_role(assignee_id) do
    case Repo.get(User, assignee_id) do
      %User{role: role, status: :active} when role in [:agent, :admin] ->
        :ok

      _ ->
        {:error,
         InvalidAttribute.exception(
           field: :assignee_id,
           value: assignee_id,
           message: "must refer to an active agent or administrator"
         )}
    end
  end

  defp validate_team_active(nil), do: :ok

  defp validate_team_active(team_id) do
    case Repo.get(Team, team_id) do
      %Team{active: true} ->
        :ok

      _ ->
        {:error,
         InvalidAttribute.exception(
           field: :team_id,
           value: team_id,
           message: "must refer to an active team"
         )}
    end
  end

  defp validate_team_membership_assignee(nil, _team_id), do: :ok

  defp validate_team_membership_assignee(_assignee_id, nil) do
    {:error,
     InvalidAttribute.exception(
       field: :team_id,
       value: nil,
       message: "must be selected when assigning a ticket"
     )}
  end

  defp validate_team_membership_assignee(assignee_id, team_id) do
    case Repo.get_by(TeamMembership, user_id: assignee_id, team_id: team_id) do
      %TeamMembership{} ->
        :ok

      _ ->
        {:error,
         InvalidAttribute.exception(
           field: :assignee_id,
           value: assignee_id,
           message: "must be a member of the selected team"
         )}
    end
  end

  defp assignment_changed?(changeset) do
    match?({:ok, _value}, Ash.Changeset.fetch_change(changeset, :assignee_id)) or
      match?({:ok, _value}, Ash.Changeset.fetch_change(changeset, :team_id))
  end
end
