defmodule Helpdesk.Notifications.EmailWorkerTest do
  use Helpdesk.DataCase
  alias Helpdesk.Accounts.User

  alias Helpdesk.Notifications.{
    Delivery,
    Notification,
    OutboxEvent,
    Worker,
    EmailWorker,
    Preference
  }

  setup do
    previous = Application.get_env(:helpdesk, Helpdesk.Mailer)

    Application.put_env(:helpdesk, Helpdesk.Mailer,
      adapter: Helpdesk.NotificationMailAdapter,
      test_pid: self()
    )

    on_exit(fn -> Application.put_env(:helpdesk, Helpdesk.Mailer, previous) end)

    user =
      Repo.insert!(%User{
        id: Ash.UUID.generate(),
        email: "#{Ash.UUID.generate()}@example.com",
        first_name: "Test",
        last_name: "User",
        hashed_password: "unused",
        role: :customer,
        status: :active,
        confirmed_at: DateTime.utc_now()
      })

    ticket =
      Ash.create!(
        Helpdesk.Support.Ticket,
        %{title: "Private subject", description: "Secret message body", priority: :medium},
        action: :create_ticket,
        actor: user
      )

    event =
      Ash.create!(
        OutboxEvent,
        %{
          source_event_id: Ash.UUID.generate(),
          ticket_id: ticket.id,
          kind: :resolved,
          candidate_recipient_ids: [user.id],
          occurred_at: DateTime.utc_now(),
          payload: %{"email_recipient_ids" => [user.id]}
        },
        action: :enqueue,
        authorize?: false
      )

    Worker.run_once()
    delivery = Repo.one!(Delivery)
    %{user: user, ticket: ticket, event: event, delivery: delivery}
  end

  test "queues once and sends a generic email with stable idempotency key", ctx do
    Worker.run_once()
    assert length(Repo.all(Delivery)) == 1
    EmailWorker.run_once()
    assert_receive {:attempted_email, email}
    assert email.to == [{"", to_string(ctx.user.email)}]
    assert email.provider_options.idempotency_key == "notification-#{ctx.delivery.id}"
    assert email.text_body =~ "/tickets/#{ctx.ticket.id}"
    refute email.text_body =~ "Secret"
    refute email.text_body =~ "Private subject"
    assert Repo.get!(Delivery, ctx.delivery.id).status == :sent
    EmailWorker.run_once()
    refute_receive {:attempted_email, _}
  end

  test "preference changes suppress queued mail and are owned by the actor", ctx do
    assert {:ok, _} =
             Ash.create(Preference, %{kind: "resolved", email_enabled: false},
               action: :set,
               actor: ctx.user
             )

    assert {:ok, _} =
             Ash.create(Preference, %{kind: "resolved", email_enabled: false},
               action: :set,
               actor: ctx.user
             )

    assert length(Repo.all(Preference)) == 1

    assert {:error, _} =
             Ash.create(Preference, %{kind: "resolved", user_id: Ash.UUID.generate()},
               action: :set,
               actor: ctx.user
             )

    EmailWorker.run_once()
    assert Repo.get!(Delivery, ctx.delivery.id).last_error_code == "preference_disabled"
    refute_receive {:attempted_email, _}
  end

  test "unconfirmed recipients are skipped", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.user, confirmed_at: nil))
    EmailWorker.run_once()
    assert Repo.get!(Delivery, ctx.delivery.id).status == :skipped
    refute_receive {:attempted_email, _}
  end

  test "access revocation prevents delivery", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.ticket, reporter_id: nil))
    EmailWorker.run_once()
    assert Repo.get!(Delivery, ctx.delivery.id).status == :skipped
    refute_receive {:attempted_email, _}
  end

  test "transient errors retry with same idempotency key and exhausted retries fail", ctx do
    Application.put_env(:helpdesk, Helpdesk.Mailer,
      adapter: Helpdesk.NotificationMailAdapter,
      test_pid: self(),
      test_result: {:error, {429, %{}}}
    )

    now = DateTime.utc_now()
    EmailWorker.run_once(now)
    assert_receive {:attempted_email, first}
    delivery = Repo.get!(Delivery, ctx.delivery.id)
    assert delivery.status == :pending
    assert DateTime.compare(delivery.next_attempt_at, now) == :gt
    Repo.update!(Ecto.Changeset.change(delivery, attempts: 7))
    EmailWorker.run_once(delivery.next_attempt_at)
    assert_receive {:attempted_email, second}
    assert first.provider_options.idempotency_key == second.provider_options.idempotency_key
    assert Repo.get!(Delivery, ctx.delivery.id).status == :failed
  end

  test "unexpired lease is ignored and expired lease is reclaimed", ctx do
    now = DateTime.utc_now()

    Repo.update!(
      Ecto.Changeset.change(ctx.delivery,
        status: :sending,
        lease_token: Ash.UUID.generate(),
        lease_expires_at: DateTime.add(now, 60, :second)
      )
    )

    assert EmailWorker.run_once(now) == []
    EmailWorker.run_once(DateTime.add(now, 61, :second))
    assert Repo.get!(Delivery, ctx.delivery.id).status == :sent
  end

  test "ordinary actors cannot inspect or forge delivery state", ctx do
    assert {:ok, []} = Ash.read(Delivery, actor: ctx.user)
    notification = Repo.one!(from n in Notification, where: n.outbox_event_id == ^ctx.event.id)

    assert {:error, _} =
             Ash.create(Delivery, %{notification_id: notification.id},
               action: :enqueue,
               actor: ctx.user
             )
  end

  test "permanent provider errors fail and only active admins can retry", ctx do
    Application.put_env(:helpdesk, Helpdesk.Mailer,
      adapter: Helpdesk.NotificationMailAdapter,
      test_pid: self(),
      test_result: {:error, {422, %{}}}
    )

    EmailWorker.run_once()
    assert Repo.get!(Delivery, ctx.delivery.id).status == :failed

    assert {:error, :forbidden} =
             Helpdesk.Notifications.Operations.retry_failed(ctx.user, :email, ctx.delivery.id)

    admin = Repo.update!(Ecto.Changeset.change(ctx.user, role: :admin))

    assert {:ok, 1} =
             Helpdesk.Notifications.Operations.retry_failed(admin, :email, ctx.delivery.id)

    assert Repo.get!(Delivery, ctx.delivery.id).status == :pending
  end

  test "disabled actors cannot change preferences using a stale actor", ctx do
    Repo.update!(Ecto.Changeset.change(ctx.user, status: :disabled))

    assert {:error, %Ash.Error.Forbidden{}} =
             Ash.create(
               Preference,
               %{kind: "resolved", email_enabled: false},
               action: :set,
               actor: ctx.user
             )
  end
end
