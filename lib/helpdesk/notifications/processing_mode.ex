defmodule Helpdesk.Notifications.ProcessingMode do
  @moduledoc """
  Selects the single owner responsible for processing notification outbox events.

  Legacy mode runs the polling worker and disables the Oban queue. AshOban mode
  enables transactional job capture and omits the polling worker.
  """

  @modes [:legacy, :ash_oban]

  @doc "Returns the configured outbox processing mode."
  def current do
    :helpdesk
    |> Application.get_env(:notification_processing_mode, :legacy)
    |> validate!()
  end

  @doc "Returns whether newly captured events should enqueue an AshOban job."
  def ash_oban?, do: current() == :ash_oban

  @doc false
  def outbox_worker_children(mode \\ current())
  def outbox_worker_children(:legacy), do: [Helpdesk.Notifications.Worker]
  def outbox_worker_children(:ash_oban), do: []

  @doc false
  def oban_config(config, mode \\ current())
  def oban_config(config, :legacy), do: Keyword.put(config, :queues, false)
  def oban_config(config, :ash_oban), do: config

  defp validate!(mode) when mode in @modes, do: mode

  defp validate!(mode) do
    raise ArgumentError,
          "invalid notification processing mode #{inspect(mode)}; expected :legacy or :ash_oban"
  end
end
