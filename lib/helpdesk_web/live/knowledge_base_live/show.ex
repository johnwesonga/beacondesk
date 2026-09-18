defmodule HelpdeskWeb.KnowledgeBaseLive.Show do
  use HelpdeskWeb, :live_view

  alias Helpdesk.Support.KnowledgeBaseArticle
  require Ash.Query
  on_mount {HelpdeskWeb.LiveUserAuth, :live_user_optional}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      if socket.assigns.current_user do
        HelpdeskWeb.NotificationState.mount(socket)
      else
        assign(socket, :notification_count, nil)
      end

    {:ok, assign(socket, :current_scope, %{user: socket.assigns.current_user})}
  end

  @impl true
  def handle_params(%{"slug" => slug}, _uri, socket) do
    article =
      KnowledgeBaseArticle
      |> Ash.Query.filter(published == true and slug == ^slug)
      |> Ash.read_one!(actor: socket.assigns.current_user)

    if article do
      {:noreply, assign(socket, article: article, page_title: article.title)}
    else
      {:noreply,
       socket |> put_flash(:error, "Article not found.") |> push_navigate(to: ~p"/help")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      notification_count={@notification_count}
      current_page={:help}
    >
      <article :if={assigns[:article]} id="kb-article" class="mx-auto max-w-3xl space-y-6">
        <.link
          id="kb-back"
          navigate={~p"/help"}
          class="inline-flex items-center gap-2 text-sm text-sky-700 hover:underline"
        >
          <.icon name="hero-arrow-left" class="size-4" />Help center
        </.link>
        <header>
          <p class="text-sm font-semibold text-sky-600">{@article.category}</p>
          <h1 class="mt-2 text-3xl font-bold">{@article.title}</h1>
          <p class="mt-3 text-slate-500">{@article.summary}</p>
        </header>
        <div
          id="kb-article-body"
          class="whitespace-pre-wrap break-words rounded-xl border border-slate-200 bg-white p-6 leading-7"
        >
          {@article.body}
        </div>
        <.link id="kb-create-ticket" navigate={~p"/ticket/new"} class="btn btn-primary">
          Still need help? Submit a ticket
        </.link>
      </article>
    </Layouts.app>
    """
  end
end
