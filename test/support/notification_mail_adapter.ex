defmodule Helpdesk.NotificationMailAdapter do
  use Swoosh.Adapter

  def deliver(email, config) do
    send(Keyword.fetch!(config, :test_pid), {:attempted_email, email})
    Keyword.get(config, :test_result, {:ok, %{id: "test-provider-id"}})
  end
end
