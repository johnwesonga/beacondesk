defmodule HelpdeskWeb.HelpdeskLive.Teams.Index do
  use HelpdeskWeb, :live_view

  alias Helpdesk.Support.{Team, TeamMembership}
  alias Helpdesk.Accounts.User
  require Ash.Query

  on_mount {HelpdeskWeb.LiveUserAuth, :live_user_required}

  @impl true
  def mount(_params, _session, socket) do
    actor = socket.assigns.current_user

    if Helpdesk.Accounts.Authorization.allowed?(actor, :manage_teams) do
      teams = Team |> Ash.Query.sort(name: :asc, id: :asc) |> Ash.read!(actor: actor)

      {:ok,
       socket
       |> assign(:page_title, "Teams")
       |> assign(:form, nil)
       |> assign(:team, nil)
       |> assign(:member_team, nil)
       |> assign(:member_form, nil)
       |> assign(:member_options, [])
       |> stream(:members, [])
       |> assign(:current_scope, %{user: actor})
       |> assign(:team_count, length(teams))
       |> assign(:can_create?, Ash.can?({Team, :create}, actor))
       |> stream(:teams, teams)}
    else
      {:ok,
       socket
       |> put_flash(:error, "You do not have permission to manage teams.")
       |> redirect(to: ~p"/tickets")}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    actor = Helpdesk.Repo.get(Helpdesk.Accounts.User, socket.assigns.current_user.id)

    if Helpdesk.Accounts.Authorization.allowed?(actor, :manage_teams) do
      socket = assign(socket, current_user: actor, member_team: nil, form: nil)

      case socket.assigns.live_action do
        :index ->
          {:noreply, assign(socket, form: nil, team: nil, page_title: "Teams")}

        :new ->
          form = AshPhoenix.Form.for_create(Team, :create, actor: actor, as: "team")
          {:noreply, assign(socket, form: to_form(form), team: nil, page_title: "New team")}

        :members ->
          case Ash.get(Team, params["id"], actor: actor) do
            {:ok, %Team{} = team} ->
              {:noreply, socket |> assign(:member_team, team) |> load_members()}

            _ ->
              {:noreply,
               socket |> put_flash(:error, "Team not found.") |> push_patch(to: ~p"/teams")}
          end

        :edit ->
          case Ash.get(Team, params["id"], actor: actor) do
            {:ok, %Team{} = team} ->
              form = AshPhoenix.Form.for_update(team, :update, actor: actor, as: "team")
              {:noreply, assign(socket, form: to_form(form), team: team, page_title: "Edit team")}

            _ ->
              {:noreply,
               socket |> put_flash(:error, "Team not found.") |> push_patch(to: ~p"/teams")}
          end
      end
    else
      {:noreply, redirect(socket, to: ~p"/tickets")}
    end
  end

  @impl true
  def handle_event("cancel", _, socket), do: {:noreply, push_patch(socket, to: ~p"/teams")}

  def handle_event("validate", %{"team" => params}, socket) do
    {:noreply,
     assign(socket, :form, AshPhoenix.Form.validate(socket.assigns.form, team_params(params)))}
  end

  def handle_event("save", %{"team" => params}, socket) do
    actor = Helpdesk.Repo.get(Helpdesk.Accounts.User, socket.assigns.current_user.id)

    if Helpdesk.Accounts.Authorization.allowed?(actor, :manage_teams) do
      case AshPhoenix.Form.submit(socket.assigns.form, params: team_params(params), actor: actor) do
        {:ok, _team} ->
          teams = Team |> Ash.Query.sort(name: :asc, id: :asc) |> Ash.read!(actor: actor)

          {:noreply,
           socket
           |> assign(:team_count, length(teams))
           |> stream(:teams, teams, reset: true)
           |> put_flash(
             :info,
             if(socket.assigns.team, do: "Team updated.", else: "Team created.")
           )
           |> push_patch(to: ~p"/teams")}

        {:error, form} ->
          {:noreply, assign(socket, :form, form)}
      end
    else
      {:noreply, redirect(socket, to: ~p"/tickets")}
    end
  end

  def handle_event(event, params, socket) when event in ["add-member", "remove-member"] do
    actor = Helpdesk.Repo.get(User, socket.assigns.current_user.id)

    if socket.assigns.member_team &&
         Helpdesk.Accounts.Authorization.allowed?(actor, :manage_team_membership) do
      socket = assign(socket, :current_user, actor)
      team_id = socket.assigns.member_team.id

      result =
        if event == "add-member" do
          Ash.create(
            TeamMembership,
            %{team_id: team_id, user_id: get_in(params, ["member", "user_id"])},
            action: :add_member,
            actor: actor
          )
        else
          query = Ash.Query.filter(TeamMembership, id == ^params["id"] and team_id == ^team_id)

          case Ash.read_one(query, actor: actor) do
            {:ok, %TeamMembership{} = membership} ->
              Ash.destroy(membership, action: :remove_member, actor: actor)

            _ ->
              {:error, "Membership not found."}
          end
        end

      case result do
        {:ok, _} ->
          {:noreply, socket |> load_members() |> put_flash(:info, "Member added.")}

        :ok ->
          {:noreply, socket |> load_members() |> put_flash(:info, "Member removed.")}

        {:error, error} ->
          message =
            if is_binary(error),
              do: error,
              else: Exception.message(Ash.Error.to_error_class(error))

          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, redirect(socket, to: ~p"/tickets")}
    end
  end

  defp load_members(socket) do
    actor = socket.assigns.current_user
    team_id = socket.assigns.member_team.id

    members =
      TeamMembership
      |> Ash.Query.filter(team_id == ^team_id)
      |> Ash.Query.load(
        user: Ash.Query.select(User, [:id, :first_name, :last_name, :email, :status])
      )
      |> Ash.read!(actor: actor)

    ids = Enum.map(members, & &1.user_id)

    users =
      User
      |> Ash.Query.filter(status == :active and role in [:agent, :admin] and id not in ^ids)
      |> Ash.Query.select([:id, :email])
      |> Ash.Query.sort(email: :asc)
      |> Ash.read!(actor: actor)

    socket
    |> stream(:members, members, reset: true)
    |> assign(:member_options, Enum.map(users, &{to_string(&1.email), &1.id}))
    |> assign(:member_form, to_form(%{"user_id" => ""}, as: :member))
  end

  defp team_params(params), do: Map.take(params, ["name", "email", "active"])

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app current_page={:teams} flash={@flash} current_scope={@current_scope}>
      <div class="space-y-6">
        <header class="flex items-center justify-between gap-4">
          <div>
            <h1 class="text-3xl font-semibold">Teams</h1>
            <p class="mt-2 text-base-content/70">
              <span id="team-count">{@team_count}</span>
              {if(@team_count == 1, do: "team", else: "teams")}
            </p>
          </div>
          <.button :if={@can_create?} id="new-team" patch={~p"/teams/new"} variant="primary">
            <.icon name="hero-plus" class="size-4" /> New team
          </.button>
        </header>

        <div id="teams" phx-update="stream" class="space-y-3">
          <div
            id="teams-empty"
            class="hidden only:block rounded-box border border-dashed border-base-300 p-8 text-center"
          >
            <.icon name="hero-user-group" class="size-8 text-base-content/60" />
            <h2 class="mt-3 font-semibold">No teams yet</h2>
            <p class="mt-2 text-base-content/70">
              Create a team to organize support and ticket assignments.
            </p>
          </div>
          <article
            :for={{dom_id, team} <- @streams.teams}
            id={dom_id}
            class="flex items-center justify-between gap-4 rounded-box border border-base-300 p-5"
          >
            <div class="min-w-0">
              <div class="flex flex-wrap items-center gap-2">
                <h2 class="break-words text-lg font-semibold">{team.name}</h2>
                <span class={[
                  "badge badge-sm",
                  if(team.active, do: "badge-success", else: "badge-neutral")
                ]}>
                  {if(team.active, do: "Active", else: "Inactive")}
                </span>
              </div>
              <p class="mt-1 break-words text-sm text-base-content/70">
                {if(team.email, do: to_string(team.email), else: "No contact email")}
              </p>
            </div>
            <.link
              id={"manage-members-#{team.id}"}
              patch={~p"/teams/#{team.id}/members"}
              class="btn btn-ghost btn-sm"
            >
              Manage members
            </.link>
            <.link
              :if={Ash.can?({team, :update}, @current_user)}
              id={"edit-team-#{team.id}"}
              patch={~p"/teams/#{team.id}/edit"}
              class="btn btn-ghost btn-sm"
              aria-label={"Edit #{team.name}"}
            >
              <.icon name="hero-pencil-square" class="size-4" /> Edit
            </.link>
          </article>
        </div>
      </div>
      <div
        :if={@form}
        id="team-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="team-modal-title"
        class="fixed inset-0 z-50 overflow-y-auto bg-slate-900/50 p-4 sm:p-10"
        phx-window-keydown="cancel"
        phx-key="escape"
      >
        <.focus_wrap id="team-dialog" class="mx-auto max-w-lg rounded-2xl bg-base-100 p-6 shadow-xl">
          <h2 id="team-modal-title" class="text-xl font-bold">{@page_title}</h2>
          <p class="mb-5 mt-2 text-sm text-base-content/70">
            Set the team's name, contact email, and availability for assignments.
          </p>
          <.form for={@form} id="team-form" phx-change="validate" phx-submit="save" class="space-y-5">
            <.input field={@form[:name]} label="Team name" required />
            <.input field={@form[:email]} type="email" label="Contact email (optional)" />
            <.input field={@form[:active]} type="checkbox" label="Active" />
            <div class="flex justify-end gap-3">
              <.link id="cancel-team" patch={~p"/teams"} class="btn btn-ghost">Cancel</.link>
              <button
                id="save-team"
                type="submit"
                phx-disable-with="Saving…"
                class="btn btn-primary"
              >
                {if @team, do: "Save changes", else: "Create team"}
              </button>
            </div>
          </.form>
        </.focus_wrap>
      </div>
      <div
        :if={@member_team}
        id="members-modal"
        role="dialog"
        aria-modal="true"
        aria-labelledby="members-title"
        class="fixed inset-0 z-50 overflow-y-auto bg-slate-900/50 p-4 sm:p-10"
        phx-window-keydown="cancel"
        phx-key="escape"
      >
        <.focus_wrap
          id="members-dialog"
          class="mx-auto max-w-xl rounded-2xl bg-base-100 p-6 shadow-xl"
        >
          <h2 id="members-title" class="mb-5 text-xl font-bold">Members of {@member_team.name}</h2>
          <div id="team-members" phx-update="stream" class="mb-5 space-y-3">
            <p id="members-empty" class="hidden only:block text-sm text-base-content/60">
              No members yet.
            </p>
            <div
              :for={{id, member} <- @streams.members}
              id={id}
              class="flex items-center justify-between gap-3 border-b border-base-200 py-3"
            >
              <div>
                <p class="font-semibold">{member.user.first_name} {member.user.last_name}</p>
                <p class="break-all text-sm">{member.user.email}</p>
                <p class="text-xs">{member.user.status}</p>
              </div>
              <button
                id={"remove-member-#{member.id}"}
                phx-click="remove-member"
                phx-value-id={member.id}
                class="btn btn-sm btn-outline"
              >
                Remove
              </button>
            </div>
          </div>
          <p class="mb-4 text-sm text-base-content/60">
            Reassign active tickets in this team before removing a member.
          </p>
          <.form for={@member_form} id="add-member-form" phx-submit="add-member">
            <.input
              field={@member_form[:user_id]}
              type="select"
              label="Add an active agent or administrator"
              prompt="Select a user"
              options={@member_options}
              required
            />
            <button
              class="btn btn-primary"
              phx-disable-with="Adding…"
              disabled={@member_options == []}
            >
              Add member
            </button>
          </.form>
          <.link id="close-members" patch={~p"/teams"} class="btn btn-ghost mt-4">Done</.link>
        </.focus_wrap>
      </div>
    </Layouts.app>
    """
  end
end
