defmodule Helpdesk.Accounts.ListAssigneesTest do
  use Helpdesk.DataCase
  alias Helpdesk.Accounts.User

  test "active staff can list only active agents and admins without user management access" do
    admin = user(:admin, :active)
    agent = user(:agent, :active)
    customer = user(:customer, :active)
    disabled = user(:agent, :disabled)

    for actor <- [admin, agent] do
      results = Ash.read!(User, action: :list_assignees, actor: actor)
      assert Enum.sort(Enum.map(results, & &1.id)) == Enum.sort([admin.id, agent.id])
    end

    for actor <- [customer, disabled, nil] do
      assert {:ok, []} = Ash.read(User, action: :list_assignees, actor: actor)
    end

    assert {:ok, []} = Ash.read(User, actor: agent)

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.update(customer, %{first_name: "Changed", role: :customer},
               action: :manage_user,
               actor: agent
             )
  end

  defp user(role, status) do
    Repo.insert!(%User{
      id: Ash.UUID.generate(),
      email: "#{Ash.UUID.generate()}@example.com",
      first_name: "Test",
      last_name: "User",
      hashed_password: "unused",
      role: role,
      status: status
    })
  end
end
