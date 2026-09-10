defmodule HelpdeskWeb.PageControllerTest do
  use HelpdeskWeb.ConnCase

  test "GET / redirects unauthenticated visitors to sign in", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/sign-in"
  end
end
