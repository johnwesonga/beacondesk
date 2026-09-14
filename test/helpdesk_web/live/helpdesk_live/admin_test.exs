defmodule HelpdeskWeb.HelpdeskLive.AdminTest do
  use HelpdeskWeb.ConnCase
  import Phoenix.LiveViewTest
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  require Ecto.Query
  alias Helpdesk.Accounts.User

  test "admin dashboard renders empty metrics, refreshes and links to team management", %{
    conn: conn
  } do
    user = user!(:admin)
    conn = conn |> init_test_session(%{}) |> store_in_session(user)
    {:ok, view, _} = live(conn, ~p"/admin")
    assert has_element?(view, "#admin-dashboard")
    assert has_element?(view, "#tickets-created", "0")
    assert has_element?(view, "#first-reply", "—")
    assert has_element?(view, "#satisfaction", "Not collected yet")
    assert has_element?(view, "#queues-empty")
    assert has_element?(view, "#notification-queue-health")
    assert has_element?(view, "#outbox-pending", "0")
    assert has_element?(view, "#outbox-failed", "0")
    assert has_element?(view, "#outbox-overdue", "0")
    assert has_element?(view, "#open-oban-dashboard[href='/admin/oban']")
    assert has_element?(view, "nav a[aria-current=page][href='/admin']")
    assert has_element?(view, "#manage-teams[href='/teams']")

    Ash.Seed.seed!(Helpdesk.Support.Ticket, %{
      title: "New request",
      description: "Example request for reporting",
      ticket_number: Ash.UUID.generate(),
      reporter_id: user.id,
      status: :new,
      priority: :medium,
      source: :web
    })

    view |> element("#refresh-operations") |> render_click()
    assert has_element?(view, "#tickets-created", "1")
    refute has_element?(view, "#queues-empty")
    assert has_element?(view, "#team-workload", "No team")

    Helpdesk.Repo.update_all(Ecto.Query.where(User, id: ^user.id), set: [role: :customer])
    view |> element("#refresh-operations") |> render_click()
    assert_redirect(view, "/tickets")
  end

  test "anonymous users, agents and customers cannot open operations", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin")

    for role <- [:customer, :agent] do
      conn = conn |> init_test_session(%{}) |> store_in_session(user!(role))
      assert {:error, {:redirect, %{to: "/tickets"}}} = live(conn, ~p"/admin")
    end
  end

  defp user!(role) do
    user =
      Ash.Seed.seed!(User, %{
        first_name: "Alex",
        last_name: "Morgan",
        role: role,
        email: "admin-view-#{Ash.UUID.generate()}@example.com",
        hashed_password: "unused"
      })

    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    Ash.Resource.put_metadata(user, :token, token)
  end
end
