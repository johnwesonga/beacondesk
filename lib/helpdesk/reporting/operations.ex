defmodule Helpdesk.Reporting.Operations do
  @moduledoc """
  Admin-only operational reporting. Read-only aggregate queries deliberately run
  at the repository layer, after checking the reporting capability.

  Reply and resolution medians use tickets created in the rolling 30-day window.
  First reply means the first public message from a current staff user other than
  the reporter. Resolution uses the ticket's current resolved_at timestamp, so
  reopened tickets without that timestamp are excluded. All boundaries are UTC.
  """
  import Ecto.Query
  alias Helpdesk.Accounts.{Authorization, User}
  alias Helpdesk.Support.{Message, Team, Ticket}
  alias Helpdesk.Repo

  def load(actor, now \\ DateTime.utc_now()) do
    with :ok <- Authorization.authorize(actor, :view_operations) do
      start = DateTime.add(now, -30, :day)
      previous = DateTime.add(start, -30, :day)
      created = count_between(:inserted_at, start, now)
      prior = count_between(:inserted_at, previous, start)

      replies =
        Repo.all(
          from t in Ticket,
            join: m in Message,
            on: m.ticket_id == t.id,
            join: u in User,
            on: u.id == m.user_id,
            where: t.inserted_at >= ^start and t.inserted_at < ^now,
            where: m.message_type == :public_reply and u.role in [:admin, :agent],
            where:
              m.user_id != t.reporter_id and m.inserted_at >= t.inserted_at and
                m.inserted_at < ^now,
            group_by: [t.id, t.inserted_at],
            select: {t.inserted_at, min(m.inserted_at)}
        )

      resolutions =
        Repo.all(
          from t in Ticket,
            where: t.inserted_at >= ^start and t.inserted_at < ^now,
            where:
              not is_nil(t.resolved_at) and t.resolved_at >= t.inserted_at and
                t.resolved_at < ^now,
            select: {t.inserted_at, t.resolved_at}
        )

      volume =
        for offset <- 0..4 do
          from = DateTime.add(start, offset * 6, :day)
          until = DateTime.add(from, 6, :day)

          %{
            id: offset,
            label: Calendar.strftime(from, "%b %d"),
            created: count_between(:inserted_at, from, until),
            resolved: count_between(:resolved_at, from, until)
          }
        end

      workload =
        Repo.all(
          from t in Ticket,
            where: t.status not in [:resolved, :closed],
            group_by: t.team_id,
            select: {t.team_id, count(t.id)}
        )
        |> Map.new()

      teams =
        Repo.all(
          from t in Team,
            order_by: [asc: t.name],
            select: %{id: t.id, name: t.name, active: t.active}
        )

      queues =
        Enum.map(teams, &Map.put(&1, :count, Map.get(workload, &1.id, 0))) ++
          [%{id: "no-team", name: "No team", active: true, count: Map.get(workload, nil, 0)}]

      {:ok,
       %{
         created: created,
         previous_created: prior,
         first_reply: median(replies),
         resolution: median(resolutions),
         volume: volume,
         queues: queues,
         chart_max: Enum.max(Enum.flat_map(volume, &[&1.created, &1.resolved]) ++ [1]),
         open_count: Enum.sum(Map.values(workload)),
         as_of: now
       }}
    end
  end

  defp count_between(attribute, start, finish) do
    Repo.one(
      from t in Ticket,
        where: field(t, ^attribute) >= ^start and field(t, ^attribute) < ^finish,
        select: count(t.id)
    )
  end

  defp median([]), do: nil

  defp median(pairs) do
    values =
      pairs
      |> Enum.map(fn {start, finish} -> DateTime.diff(finish, start, :second) end)
      |> Enum.sort()

    middle = div(length(values), 2)

    if rem(length(values), 2) == 0,
      do: (Enum.at(values, middle - 1) + Enum.at(values, middle)) / 2,
      else: Enum.at(values, middle)
  end
end
