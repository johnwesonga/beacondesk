defmodule Helpdesk.Support do
  use Ash.Domain,
    otp_app: :helpdesk

  resources do
    resource Helpdesk.Support.Ticket
    resource Helpdesk.Support.Team
    resource Helpdesk.Support.Message
    resource Helpdesk.Support.Attachment
    resource Helpdesk.Support.TeamMembership
    resource Helpdesk.Support.TicketEvent
  end
end
