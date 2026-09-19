defmodule Helpdesk.Support.Types.TicketPriority do
  use Ash.Type.Enum,
    values: [
      :low,
      :medium,
      :high,
      :critical
    ]
end
