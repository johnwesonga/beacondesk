defmodule HelpdeskWeb.ObanDashboardAccessTest do
  use HelpdeskWeb.ConnCase

  import AshAuthentication.Plug.Helpers, only: [store_in_session: 2]

  alias Helpdesk.Accounts.User

  test "Oban dashboard requires an active administrator", %{conn: conn} do
    conn = get(conn, "/admin/oban")
    assert redirected_to(conn) == "/sign-in"

    customer = user!(:customer)

    conn =
      build_conn()
      |> init_test_session(%{})
      |> store_in_session(customer)
      |> get("/admin/oban")

    assert redirected_to(conn) == "/tickets"

    admin = user!(:admin)

    conn =
      build_conn()
      |> assign(:current_user, admin)
      |> HelpdeskWeb.Plugs.RequireAdministrator.call([])

    refute conn.halted
    assert conn.assigns.current_user.id == admin.id

    assert %{plug: Phoenix.LiveView.Plug} =
             Phoenix.Router.route_info(
               HelpdeskWeb.Router,
               "GET",
               "/admin/oban",
               "localhost"
             )
  end

  defp user!(role) do
    user =
      Ash.Seed.seed!(User, %{
        first_name: "Queue",
        last_name: "Viewer",
        role: role,
        email: "queue-viewer-#{Ash.UUID.generate()}@example.com",
        hashed_password: "unused"
      })

    {:ok, token, _claims} = AshAuthentication.Jwt.token_for_user(user)
    Ash.Resource.put_metadata(user, :token, token)
  end
end
