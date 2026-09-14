defmodule Helpdesk.Notifications.ProcessingModeTest do
  use ExUnit.Case, async: false

  alias Helpdesk.Notifications.{ProcessingMode, Worker}

  test "legacy mode starts only the poller and disables Oban queue execution" do
    config = [queues: [notification_outbox: 1], repo: Helpdesk.Repo]

    assert ProcessingMode.outbox_worker_children(:legacy) == [Worker]
    assert ProcessingMode.oban_config(config, :legacy)[:queues] == false
  end

  test "AshOban mode enables its queue and omits the legacy poller" do
    config = [queues: [notification_outbox: 1], repo: Helpdesk.Repo]

    assert ProcessingMode.outbox_worker_children(:ash_oban) == []
    assert ProcessingMode.oban_config(config, :ash_oban)[:queues] == [notification_outbox: 1]
  end

  test "test runtime uses AshOban as the sole outbox owner" do
    assert ProcessingMode.current() == :ash_oban
    assert ProcessingMode.ash_oban?()
    assert ProcessingMode.outbox_worker_children() == []
    refute Process.whereis(Worker)
  end
end
