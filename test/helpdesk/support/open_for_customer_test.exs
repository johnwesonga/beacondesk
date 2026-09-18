defmodule Helpdesk.Support.OpenForCustomerTest do
  use Helpdesk.DataCase

  alias Helpdesk.Accounts.User
  alias Helpdesk.Support.{Ticket, TicketEvent}

  setup do
    %{agent: user!(:agent), customer: user!(:customer)}
  end

  test "staff creation records ownership, creator, events and notifications", ctx do
    for actor <- [ctx.agent, user!(:admin)] do
      ticket =
        Ash.create!(Ticket, params(ctx.customer.id), action: :open_for_customer, actor: actor)

      assert ticket.customer_id == ctx.customer.id
      assert ticket.reporter_id == ctx.customer.id
      assert ticket.created_by_id == actor.id
      assert ticket.status == :new
      assert ticket.source == :web
      assert Ash.get!(Ticket, ticket.id, actor: ctx.customer).id == ticket.id
      assert Repo.get_by!(TicketEvent, ticket_id: ticket.id).event_type == :ticket_created
      assert Repo.get_by!(Helpdesk.Audit.Event, ticket_id: ticket.id).actor_id == actor.id
      event = Repo.get_by!(Helpdesk.Notifications.OutboxEvent, ticket_id: ticket.id)
      assert event.kind == :ticket_created
      assert event.actor_id == actor.id

      message =
        Ash.create!(
          Helpdesk.Support.Message,
          %{ticket_id: ticket.id, body: "We are looking into your request.", source: :web},
          action: :add_reply,
          actor: actor
        )

      reply_event = Repo.get_by!(Helpdesk.Notifications.OutboxEvent, message_id: message.id)
      assert ctx.customer.id in reply_event.candidate_recipient_ids
    end
  end

  test "customers, disabled staff and anonymous actors cannot create on behalf of customers",
       ctx do
    for actor <- [ctx.customer, user!(:agent, :disabled), nil] do
      assert {:error, _} =
               Ash.create(Ticket, params(ctx.customer.id),
                 action: :open_for_customer,
                 actor: actor
               )
    end

    assert Ash.count!(Ticket, authorize?: false) == 0
  end

  test "requires an existing active customer and rejects staff or forged creator inputs", ctx do
    for id <- [nil, "invalid", Ash.UUID.generate(), ctx.agent.id, user!(:customer, :disabled).id] do
      assert {:error, _} =
               Ash.create(Ticket, params(id), action: :open_for_customer, actor: ctx.agent)
    end

    assert {:error, _} =
             Ash.create(Ticket, Map.put(params(ctx.customer.id), :created_by_id, ctx.customer.id),
               action: :open_for_customer,
               actor: ctx.agent
             )

    assert Ash.count!(Ticket, authorize?: false) == 0
  end

  test "only active staff can look up active customers", ctx do
    user!(:customer, :disabled)
    assert [customer] = Ash.read!(User, action: :list_customers, actor: ctx.agent)
    assert customer.id == ctx.customer.id

    for actor <- [ctx.customer, user!(:agent, :disabled), nil] do
      assert {:ok, []} = Ash.read(User, action: :list_customers, actor: actor)
    end
  end

  defp params(customer_id) do
    %{
      customer_id: customer_id,
      title: "Billing request",
      description: "Customer needs help with a payment.",
      priority: :medium
    }
  end

  defp user!(role, status \\ :active) do
    Ash.Seed.seed!(User, %{
      first_name: "Test",
      last_name: "User",
      email: "on-behalf-#{Ash.UUID.generate()}@example.com",
      hashed_password: "unused",
      role: role,
      status: status
    })
  end
end
