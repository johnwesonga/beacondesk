defmodule Helpdesk.Audit.Coverage do
  @inventory %{
    {Helpdesk.Support.Ticket, :create} => "ticket.created",
    {Helpdesk.Support.Ticket, :update} => "ticket.updated",
    {Helpdesk.Support.Ticket, :assign} => "ticket.assigned",
    {Helpdesk.Support.Message, :create} => "message.add.reply",
    {Helpdesk.Support.Attachment, :create} => "attachment.add"
  }

  def inventory, do: @inventory
end
