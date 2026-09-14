defmodule HelpdeskWeb.Plugs.RequireAdministrator do
  @moduledoc "Ensures operational tooling is accessible only to active administrators."

  import Plug.Conn
  import Phoenix.Controller

  alias Helpdesk.Accounts.User
  alias Helpdesk.Repo

  def init(opts), do: opts

  def call(%{assigns: %{current_user: %{id: id}}} = conn, _opts) do
    case Repo.get(User, id) do
      %User{role: :admin, status: :active} = user -> assign(conn, :current_user, user)
      _user -> conn |> redirect(to: "/tickets") |> halt()
    end
  end

  def call(conn, _opts), do: conn |> redirect(to: "/sign-in") |> halt()
end
