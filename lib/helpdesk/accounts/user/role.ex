defmodule Helpdesk.Accounts.User.Role do
  @moduledoc """
  Defines the fixed administrator roles supported by Heldesk.


  """

  use Ash.Type.Enum, values: [:admin, :agent, :customer]
end
