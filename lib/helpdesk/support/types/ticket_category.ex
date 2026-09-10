defmodule Helpdesk.Support.Types.TicketCategory do
  use Ash.Type.Enum,
    values: [
      :billing,
      :bug,
      :feature,
      :howto
    ]
end
