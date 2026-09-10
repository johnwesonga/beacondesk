defmodule Helpdesk.Reporting.OperationsTest do
  use Helpdesk.DataCase
  alias Helpdesk.Accounts.User
  alias Helpdesk.Reporting.Operations
  alias Helpdesk.Support.{Ticket, Team, Message}

  test "denies non-admins and disabled administrators" do
    for actor <- [
          nil,
          %User{role: :customer},
          %User{role: :agent},
          %User{role: :admin, status: :disabled}
        ] do
      assert {:error, :forbidden} = Operations.load(actor)
    end
  end

  test "calculates window boundaries, medians, volume and current workload" do
    now = ~U[2026-09-08 12:00:00.000000Z]
    customer = user!(:customer)
    agent = user!(:agent)
    team = Ash.Seed.seed!(Team, %{name: "Billing", active: false})
    ticket = ticket!(customer, DateTime.add(now, -2, :day), %{team_id: team.id})
    start = DateTime.add(now, -30, :day)

    resolved =
      ticket!(customer, start, %{status: :resolved, resolved_at: DateTime.add(start, 7200)})

    ticket!(customer, DateTime.add(start, -1), %{})
    ticket!(customer, now, %{status: :closed})
    message!(ticket, customer, 60, :public_reply)
    message!(ticket, agent, 120, :internal_note)
    message!(ticket, agent, 600, :public_reply)
    message!(ticket, agent, 1200, :public_reply)
    message!(resolved, agent, 1800, :public_reply)

    assert {:ok, report} = Operations.load(%User{role: :admin}, now)
    assert report.created == 2
    assert report.previous_created == 1
    assert report.first_reply == 1200
    assert report.resolution == 7200
    assert report.open_count == 2
    assert Enum.sum(Enum.map(report.volume, & &1.created)) == 2
    assert Enum.sum(Enum.map(report.volume, & &1.resolved)) == 1
    assert Enum.find(report.queues, &(&1.id == team.id)).count == 1
    assert Enum.find(report.queues, &(&1.id == "no-team")).count == 1
  end

  defp user!(role) do
    Ash.Seed.seed!(User, %{
      email: "#{Ash.UUID.generate()}@example.com",
      role: role,
      first_name: "Test",
      last_name: "User",
      hashed_password: "unused"
    })
  end

  defp ticket!(user, inserted_at, extra) do
    Ash.Seed.seed!(
      Ticket,
      Map.merge(
        %{
          title: "Reporting ticket",
          description: "Reporting test description",
          ticket_number: Ash.UUID.generate(),
          reporter_id: user.id,
          inserted_at: inserted_at,
          status: :open,
          priority: :medium,
          source: :web
        },
        extra
      )
    )
  end

  defp message!(ticket, user, seconds, type) do
    Ash.Seed.seed!(Message, %{
      ticket_id: ticket.id,
      user_id: user.id,
      body: "Reply",
      source: :web,
      message_type: type,
      inserted_at: DateTime.add(ticket.inserted_at, seconds)
    })
  end
end
