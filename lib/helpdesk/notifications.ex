defmodule Helpdesk.Notifications do
  @moduledoc """
  Durable notification infrastructure. Event production and delivery are added
  separately; ordinary application actors cannot access the internal outbox.
  """
  use Ash.Domain, otp_app: :helpdesk

  resources do
    resource Helpdesk.Notifications.OutboxEvent
  end
end
