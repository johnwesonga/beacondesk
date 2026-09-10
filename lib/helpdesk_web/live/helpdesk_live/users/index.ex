defmodule HelpdeskWeb.HelpdeskLive.Users.Index do
  use HelpdeskWeb, :live_view
  alias Helpdesk.Accounts.{User, Authorization}
  require Ash.Query
  on_mount {HelpdeskWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_, _, socket) do
    if Authorization.allowed?(socket.assigns.current_user, :manage_users) do
      {:ok,
       socket
       |> assign(:current_scope, %{user: socket.assigns.current_user})
       |> assign(:page_title, "Users")
       |> assign(:form, nil)
       |> assign(:editing, nil)
       |> assign(:filters, %{"q" => "", "role" => "", "status" => ""})
       |> assign(:role_options, options(User.Role.values()))
       |> assign(:status_options, options(User.Status.values()))
       |> refresh()}
    else
      {:ok, redirect(socket, to: ~p"/tickets")}
    end
  end

  @impl true
  def handle_event(event, params, socket) do
    actor = Helpdesk.Repo.get(User, socket.assigns.current_user.id)

    if Authorization.allowed?(actor, :manage_users) do
      dispatch(event, params, assign(socket, :current_user, actor))
    else
      {:noreply,
       socket
       |> put_flash(:error, "User management is restricted to active administrators.")
       |> redirect(to: ~p"/tickets")}
    end
  end

  defp dispatch("filter", %{"filters" => filters}, socket) do
    filters = Map.take(filters, ["q", "role", "status"])
    {:noreply, socket |> assign(:filters, filters) |> refresh()}
  end

  defp dispatch("new", _, socket) do
    form =
      AshPhoenix.Form.for_create(User, :create_user,
        actor: socket.assigns.current_user,
        as: "user"
      )

    {:noreply, socket |> assign(:editing, nil) |> assign(:form, to_form(form))}
  end

  defp dispatch("edit", %{"id" => id}, socket) do
    case Ash.get(User, id, actor: socket.assigns.current_user) do
      {:ok, %User{} = user} ->
        form =
          AshPhoenix.Form.for_update(user, :manage_user,
            actor: socket.assigns.current_user,
            as: "user",
            params: %{"role" => to_string(user.role)}
          )

        {:noreply, socket |> assign(:editing, user.id) |> assign(:form, to_form(form))}

      _ ->
        {:noreply, put_flash(socket, :error, "User not found.")}
    end
  end

  defp dispatch("cancel", _, socket), do: {:noreply, assign(socket, :form, nil)}

  defp dispatch("validate", %{"user" => params}, socket) do
    {:noreply, assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, params))}
  end

  defp dispatch("save", %{"user" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.form,
           params: params,
           actor: socket.assigns.current_user
         ) do
      {:ok, _user} ->
        {:noreply, socket |> assign(:form, nil) |> refresh() |> put_flash(:info, "User saved.")}

      {:error, form} ->
        {:noreply, assign(socket, :form, form)}
    end
  end

  defp refresh(socket) do
    filters = socket.assigns.filters
    q = String.trim(filters["q"] || "")

    query =
      User
      |> Ash.Query.select([:id, :first_name, :last_name, :email, :role, :status, :confirmed_at])
      |> Ash.Query.sort(email: :asc)

    query =
      if q == "",
        do: query,
        else:
          Ash.Query.filter(
            query,
            contains(email, ^q) or contains(first_name, ^q) or contains(last_name, ^q)
          )

    query =
      Enum.reduce(
        [{:role, User.Role.values()}, {:status, User.Status.values()}],
        query,
        fn {field, allowed}, query ->
          value = Enum.find(allowed, &(to_string(&1) == filters[to_string(field)]))
          if value, do: Ash.Query.filter_input(query, %{field => %{eq: value}}), else: query
        end
      )

    users = Ash.read!(query, actor: socket.assigns.current_user)

    socket
    |> assign(:user_count, length(users))
    |> assign(:filter_form, to_form(filters, as: :filters))
    |> stream(:users, users, reset: true)
  end

  defp options(values), do: Enum.map(values, &{String.capitalize(to_string(&1)), &1})

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} current_page={:users}>
      <header class="mb-6 flex items-end justify-between gap-4">
        <div>
          <p class="text-sm font-semibold text-violet-600">Administration</p>
          <h1 class="text-3xl font-black">Users</h1>
          <p class="mt-2 text-slate-500">
            Manage account details, roles and access. {@user_count} users found.
          </p>
        </div>
        <button id="new-user" phx-click="new" class="btn btn-primary">
          <.icon name="hero-plus" class="size-4" />Add user
        </button>
      </header>
      <.form
        for={@filter_form}
        id="user-filters"
        phx-change="filter"
        phx-submit="filter"
        class="mb-5 grid gap-4 rounded-2xl border border-slate-200 bg-white p-4 sm:grid-cols-3"
      >
        <.input
          field={@filter_form[:q]}
          type="search"
          label="Search users"
          phx-debounce="300"
          placeholder="Name or email"
        />
        <.input
          field={@filter_form[:role]}
          type="select"
          label="Role"
          prompt="All roles"
          options={@role_options}
        />
        <.input
          field={@filter_form[:status]}
          type="select"
          label="Status"
          prompt="All statuses"
          options={@status_options}
        />
      </.form>
      <div
        id="users"
        phx-update="stream"
        class="divide-y divide-slate-100 overflow-hidden rounded-2xl border border-slate-200 bg-white"
      >
        <p id="users-empty" class="hidden only:block p-8 text-center text-slate-500">
          No users match these filters.
        </p>
        <article
          :for={{id, user} <- @streams.users}
          id={id}
          class="flex flex-wrap items-center justify-between gap-4 p-5"
        >
          <div>
            <h2 class="font-bold">{user.first_name} {user.last_name}</h2>
            <p class="break-all text-sm text-slate-500">{user.email}</p>
            <p class="mt-2 text-xs text-slate-500">
              {String.capitalize(to_string(user.role))} · {String.capitalize(to_string(user.status))} · {if user.confirmed_at,
                do: "Email confirmed",
                else: "Email unconfirmed"}
            </p>
          </div>
          <button
            id={"edit-user-#{user.id}"}
            phx-click="edit"
            phx-value-id={user.id}
            class="btn btn-sm btn-outline"
          >
            Edit
          </button>
        </article>
      </div>
      <div
        :if={@form}
        id="user-modal"
        class="fixed inset-0 z-50 overflow-y-auto bg-slate-900/50 p-4 sm:p-10"
        role="dialog"
        aria-modal="true"
        aria-labelledby="user-form-title"
        phx-window-keydown="cancel"
        phx-key="escape"
      >
        <.focus_wrap id="user-dialog" class="mx-auto max-w-lg rounded-2xl bg-base-100 p-6 shadow-xl">
          <h2 id="user-form-title" class="mb-5 text-xl font-bold">
            {if @editing, do: "Edit user", else: "Add user"}
          </h2>
          <.form for={@form} id="user-form" phx-change="validate" phx-submit="save">
            <.input field={@form[:first_name]} label="First name" required />
            <.input field={@form[:last_name]} label="Last name" required />
            <.input :if={!@editing} field={@form[:email]} type="email" label="Email" required />
            <.input field={@form[:role]} type="select" label="Role" options={@role_options} required />
            <.input
              field={@form[:status]}
              type="select"
              label="Status"
              options={@status_options}
              required
            />
            <.input
              :if={!@editing}
              field={@form[:password]}
              type="password"
              label="Password"
              autocomplete="new-password"
              minlength="8"
              required
            />
            <.input
              :if={!@editing}
              field={@form[:password_confirmation]}
              type="password"
              label="Confirm password"
              autocomplete="new-password"
              required
            />
            <p :if={@editing == @current_user.id} class="my-3 text-sm text-base-content/60">
              Your own account must remain an active administrator.
            </p>
            <div class="mt-5 flex justify-end gap-3">
              <button type="button" phx-click="cancel" class="btn btn-ghost">Cancel</button><button
                id="save-user"
                phx-disable-with="Saving…"
                class="btn btn-primary"
              >Save user</button>
            </div>
          </.form>
        </.focus_wrap>
      </div>
    </Layouts.app>
    """
  end
end
