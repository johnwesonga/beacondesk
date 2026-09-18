defmodule HelpdeskWeb.KnowledgeBaseLive.Index do
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

    categories =
      KnowledgeBaseArticle
      |> Ash.Query.filter(published == true)
      |> Ash.Query.select([:category])
      |> Ash.read!(actor: socket.assigns.current_user)
      |> Enum.map(& &1.category)
      |> Enum.uniq()
      |> Enum.sort()

    {:ok,
     socket
     |> assign(
       current_scope: %{user: socket.assigns.current_user},
       page_title: "Help center",
       categories: categories
     )
     |> stream(:articles, [])}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    query = params |> Map.get("q", "") |> String.trim() |> String.slice(0, 200)
    category = Map.get(params, "category", "")

    page =
      case Integer.parse(Map.get(params, "page", "1")) do
        {page, ""} when page > 0 -> min(page, 10_000)
        _ -> 1
      end

    articles =
      KnowledgeBaseArticle
      |> Ash.Query.filter(published == true)
      |> search(query)
      |> category(category)
      |> Ash.Query.sort(featured: :desc, position: :asc, title: :asc, id: :asc)
      |> Ash.Query.select([:title, :slug, :summary, :category, :featured])
      |> Ash.Query.limit(21)
      |> Ash.Query.offset((page - 1) * 20)
      |> Ash.read!(actor: socket.assigns.current_user)

    {:noreply,
     socket
     |> assign(
       form: to_form(%{"q" => query, "category" => category}, as: :search),
       query: query,
       category: category,
       page: page,
       more?: length(articles) > 20
     )
     |> stream(:articles, Enum.take(articles, 20), reset: true)}
  end

  @impl true
  def handle_event("search", %{"search" => params}, socket) do
    {:noreply, push_patch(socket, to: ~p"/help?#{Map.take(params, ["q", "category"])}")}
  end

  defp search(query, ""), do: query

  defp search(query, term) do
    term = String.downcase(term)

    Ash.Query.filter(
      query,
      contains(string_downcase(title), ^term) or contains(string_downcase(summary), ^term) or
        contains(string_downcase(body), ^term)
    )
  end

  defp category(query, ""), do: query
  defp category(query, category), do: Ash.Query.filter(query, category == ^category)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      notification_count={@notification_count}
      current_page={:help}
    >
      <section id="knowledge-base" class="mx-auto max-w-4xl space-y-6">
        <header>
          <p class="text-sm font-semibold text-sky-600">Help center</p>
          <h1 class="mt-2 text-3xl font-bold">How can we help?</h1>
          <p class="mt-2 text-slate-500">Find answers and guidance in our knowledge base.</p>
        </header>
        <.form
          for={@form}
          id="kb-search-form"
          phx-change="search"
          phx-submit="search"
          class="grid gap-3 rounded-xl border border-slate-200 bg-white p-5 sm:grid-cols-3"
        >
          <div class="sm:col-span-2">
            <.input
              field={@form[:q]}
              id="kb-search"
              type="search"
              label="Search articles"
              placeholder="Search by topic or keyword"
              phx-debounce="300"
              maxlength="200"
            />
          </div>
          <.input
            field={@form[:category]}
            id="kb-category"
            type="select"
            label="Category"
            prompt="All categories"
            options={@categories}
          />
          <.button id="kb-search-submit" type="submit">Search</.button>
        </.form>
        <div id="kb-articles" phx-update="stream" class="space-y-4">
          <p
            id="kb-empty"
            class="hidden only:block rounded-xl border border-slate-200 p-6 text-slate-500"
            role="status"
          >
            No articles found. Try another search or category.
          </p>
          <article
            :for={{id, article} <- @streams.articles}
            id={id}
            class="rounded-xl border border-slate-200 bg-white p-5"
          >
            <div class="mb-2 flex items-center gap-2 text-xs text-slate-500">
              <span>{article.category}</span>
              <span :if={article.featured} class="rounded bg-sky-50 px-2 py-1 text-sky-700">
                Featured
              </span>
            </div>
            <.link
              id={"kb-article-#{article.id}"}
              navigate={~p"/help/#{article.slug}"}
              class="text-lg font-semibold text-sky-700 hover:underline"
            >
              {article.title}
            </.link>
            <p class="mt-2 text-sm leading-6 text-slate-600">{article.summary}</p>
          </article>
        </div>
        <nav :if={@page > 1 or @more?} aria-label="Article pages" class="flex justify-between">
          <.link
            :if={@page > 1}
            id="kb-previous"
            patch={~p"/help?#{%{q: @query, category: @category, page: @page - 1}}"}
            class="btn btn-ghost"
          >
            Previous
          </.link>
          <.link
            :if={@more?}
            id="kb-next"
            patch={~p"/help?#{%{q: @query, category: @category, page: @page + 1}}"}
            class="btn btn-ghost"
          >
            Next
          </.link>
        </nav>
        <p class="text-sm text-slate-500">
          Still need help?
          <.link
            id="kb-create-ticket"
            navigate={~p"/ticket/new"}
            class="font-semibold text-sky-700 hover:underline"
          >
            Submit a ticket
          </.link>
        </p>
      </section>
    </Layouts.app>
    """
  end
end
