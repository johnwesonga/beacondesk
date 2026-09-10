defmodule HelpdeskWeb.HelpdeskLive.UsersTest do
  use HelpdeskWeb.ConnCase
  import Phoenix.LiveViewTest
  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]
  alias Helpdesk.Accounts.User

  test "admins create, filter and edit accounts", %{conn: conn} do
    admin = user!(:admin)
    conn = conn |> init_test_session(%{}) |> store_in_session(admin)
    {:ok, view, _} = live(conn, ~p"/users")
    view |> element("#new-user") |> render_click()

    view
    |> form("#user-form",
      user: %{
        first_name: "Peter",
        last_name: "White",
        email: "peter@example.com",
        role: "agent",
        status: "active",
        password: "password123",
        password_confirmation: "password123"
      }
    )
    |> render_submit()

    refute has_element?(view, "#user-modal")
    user = Helpdesk.Repo.get_by!(User, email: "peter@example.com")
    assert user.role == :agent
    assert Bcrypt.verify_pass("password123", user.hashed_password)
    view |> element("#edit-user-#{user.id}") |> render_click()

    view
    |> form("#user-form", user: %{first_name: "Pete", role: "customer", status: "disabled"})
    |> render_submit()

    assert Helpdesk.Repo.get!(User, user.id).status == :disabled
    assert Helpdesk.Repo.get!(User, user.id).role == :customer
    view |> form("#user-filters", filters: %{q: "Pete"}) |> render_change()
    assert has_element?(view, "#users-#{user.id}")
    refute has_element?(view, "#users-#{admin.id}")
  end

  test "resource policies deny non-admin management and protect own access", %{conn: conn} do
    admin = user!(:admin)

    for role <- [:customer, :agent] do
      actor = user!(role)
      conn = conn |> init_test_session(%{}) |> store_in_session(actor)
      assert {:error, {:redirect, %{to: "/tickets"}}} = live(conn, ~p"/users")

      assert {:error, _} =
               Ash.update(admin, %{role: :customer}, action: :manage_user, actor: actor)

      assert {:error, _} =
               Ash.create(
                 User,
                 %{
                   first_name: "Bad",
                   last_name: "Actor",
                   email: "bad@example.com",
                   role: :admin,
                   password: "password123",
                   password_confirmation: "password123"
                 },
                 action: :create_user,
                 actor: actor
               )
    end

    assert {:error, _} = Ash.update(admin, %{role: :customer}, action: :manage_user, actor: admin)

    assert {:error, _} =
             Ash.update(admin, %{role: :admin, status: :disabled},
               action: :manage_user,
               actor: admin
             )

    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/users")
  end

  defp user!(role) do
    user =
      Ash.Seed.seed!(User, %{
        first_name: "Alex",
        last_name: "Morgan",
        role: role,
        email: "users-#{Ash.UUID.generate()}@example.com",
        hashed_password: "unused"
      })

    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    Ash.Resource.put_metadata(user, :token, token)
  end
end
