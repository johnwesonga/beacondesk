defmodule Helpdesk.Support.Types.TicketStatus do
  use Ash.Type.Enum,
    values: [
      :new,
      :open,
      :waiting_on_customer,
      :waiting_on_support,
      :resolved,
      :closed
    ]
end
