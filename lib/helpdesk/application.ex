defmodule Helpdesk.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    mode = Helpdesk.Notifications.ProcessingMode.current()

    oban_config =
      [Helpdesk.Notifications]
      |> AshOban.config(Application.fetch_env!(:helpdesk, Oban))
      |> Helpdesk.Notifications.ProcessingMode.oban_config(mode)

    children =
      [
        HelpdeskWeb.Telemetry,
        Helpdesk.Repo,
        {Oban, oban_config},
        {DNSCluster, query: Application.get_env(:helpdesk, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Helpdesk.PubSub},
        {Task.Supervisor, name: Helpdesk.NotificationTasks}
      ] ++
        Helpdesk.Notifications.ProcessingMode.outbox_worker_children(mode) ++
        [
          Helpdesk.Notifications.EmailWorker,
          HelpdeskWeb.Endpoint,
          {AshAuthentication.Supervisor, [otp_app: :helpdesk]}
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Helpdesk.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    HelpdeskWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
