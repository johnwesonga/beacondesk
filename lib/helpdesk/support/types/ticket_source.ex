defmodule Helpdesk.Support.Types.TicketSource do
  use Ash.Type.Enum,
    values: [
      :web,
      :email,
      :phone,
      :api
    ]
end
