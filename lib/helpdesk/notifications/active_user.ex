defmodule Helpdesk.Notifications.ActiveUser do
  @moduledoc false
  use Ash.Policy.SimpleCheck
  def describe(_), do: "actor is still an active account"

  def match?(%{id: id}, _, _) do
    match?(%{status: :active}, Helpdesk.Repo.get(Helpdesk.Accounts.User, id))
  end

  def match?(_, _, _), do: false
end
