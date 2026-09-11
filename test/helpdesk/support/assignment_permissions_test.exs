defmodule Helpdesk.Support.AssignmentPermissionsTest do
  use Helpdesk.DataCase
  alias Helpdesk.Accounts.User
  alias Helpdesk.Support.{Ticket, Team, TeamMembership}

  setup do
    customer = user(:customer)
    admin = user(:admin)
    agent = user(:agent)
    team = Ash.create!(Team, %{name: Ash.UUID.generate()}, authorize?: false)
    Ash.create!(TeamMembership, %{team_id: team.id, user_id: agent.id}, authorize?: false)
    %{customer: customer, admin: admin, agent: agent, team: team}
  end

  test "customer may create an unassigned ticket but cannot submit routing fields", ctx do
    assert {:ok, _} = create(ctx.customer, %{})

    for assignment <- [
          %{team_id: ctx.team.id},
          %{team_id: ctx.team.id, assignee_id: ctx.agent.id}
        ] do
      assert {:error, %Ash.Error.Forbidden{}} = create(ctx.customer, assignment)
    end
  end

  test "staff create valid assignments and editing preserves the reporter", ctx do
    for actor <- [ctx.admin, ctx.agent] do
      assert {:ok, ticket} = create(actor, %{team_id: ctx.team.id, assignee_id: ctx.agent.id})
      assert ticket.assignee_id == ctx.agent.id
    end

    {:ok, ticket} = create(ctx.customer, %{})

    updated =
      Ash.update!(ticket, %{team_id: ctx.team.id, assignee_id: ctx.agent.id},
        action: :update_ticket,
        actor: ctx.admin
      )

    assert updated.reporter_id == ctx.customer.id
    assert updated.assignee_id == ctx.agent.id
  end

  test "invalid assignments are rejected on creation and ordinary editing", ctx do
    {:ok, ticket} = create(ctx.customer, %{})
    other_team = Ash.create!(Team, %{name: Ash.UUID.generate()}, authorize?: false)
    Repo.update!(Ecto.Changeset.change(ctx.agent, status: :disabled))

    for attributes <- [
          %{team_id: ctx.team.id, assignee_id: ctx.agent.id},
          %{team_id: other_team.id, assignee_id: ctx.customer.id}
        ] do
      assert {:error, %Ash.Error.Invalid{}} = create(ctx.admin, attributes)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.update(ticket, attributes, action: :update_ticket, actor: ctx.admin)
    end
  end

  test "disabled actor cannot use assign and inactive existing team is revalidated", ctx do
    {:ok, ticket} = create(ctx.admin, %{team_id: ctx.team.id})
    disabled = %{ctx.admin | status: :disabled}

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(ticket, %{assignee_id: ctx.agent.id}, action: :assign, actor: disabled)

    Repo.update!(Ecto.Changeset.change(ctx.team, active: false))

    assert {:error, %Ash.Error.Invalid{}} =
             Ash.update(ticket, %{assignee_id: ctx.agent.id}, action: :assign, actor: ctx.admin)
  end

  defp create(actor, assignment) do
    Ash.create(
      Ticket,
      Map.merge(
        %{title: "Billing help", description: "Please explain these fees", priority: :medium},
        assignment
      ),
      action: :create_ticket,
      actor: actor
    )
  end

  defp user(role) do
    Repo.insert!(%User{
      id: Ash.UUID.generate(),
      email: "#{Ash.UUID.generate()}@example.com",
      first_name: "Test",
      last_name: "User",
      hashed_password: "unused",
      role: role,
      status: :active
    })
  end
end
