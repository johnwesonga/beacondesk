defmodule Helpdesk.Accounts.User.Status do
  use Ash.Type.Enum, values: [:active, :disabled]
end
