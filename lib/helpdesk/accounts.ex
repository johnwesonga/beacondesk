defmodule Helpdesk.Accounts do
  use Ash.Domain,
    otp_app: :helpdesk

  resources do
    resource Helpdesk.Accounts.Token
    resource Helpdesk.Accounts.User
  end
end
