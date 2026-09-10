defmodule Helpdesk.Support.TicketTest do
  use ExUnit.Case, async: true

  alias Helpdesk.Accounts.User
  alias Helpdesk.Support.Ticket

  test "ticket creation generates a ticket number without client input" do
    changeset = ticket_changeset()

    assert changeset.valid?
    assert Ash.Changeset.get_attribute(changeset, :ticket_number) =~ ~r/^TKT-[A-Z2-7]{16}$/
  end

  test "ticket creation rejects a client-supplied ticket number" do
    changeset = ticket_changeset(%{ticket_number: "TKT-CUSTOM"})

    refute changeset.valid?
    refute Ash.Changeset.get_attribute(changeset, :ticket_number) == "TKT-CUSTOM"
  end

  defp ticket_changeset(extra_params \\ %{}) do
    params =
      Map.merge(
        %{
          title: "Unable to sign in",
          description: "My password is not working",
          status: :new,
          priority: :medium,
          source: :web
        },
        extra_params
      )

    Ash.Changeset.for_create(Ticket, :create_ticket, params,
      actor: %User{id: Ash.UUID.generate()}
    )
  end
end
