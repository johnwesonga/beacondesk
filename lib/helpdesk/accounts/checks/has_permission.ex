defmodule Helpdesk.Accounts.Checks.HasPermission do
  @moduledoc """
  Provides a check to verify if a user has a specific permission.
  """

  use Ash.Policy.SimpleCheck
  alias Helpdesk.Accounts.Authorization

  @impl true
  def describe(options),
    do: "actor has one of #{inspect(options[:permissions] || options[:permission])}"

  @impl true
  def match?(actor, _context, options) do
    permissions = options |> Keyword.get(:permissions, options[:permission]) |> List.wrap()
    Authorization.any_allowed?(actor, permissions)
  end
end
