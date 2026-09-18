defmodule HelpdeskWeb.AttachmentComponents do
  use HelpdeskWeb, :html

  attr :attachment, Helpdesk.Support.Attachment, required: true

  def file_link(assigns) do
    ~H"""
    <.link
      href={~p"/attachments/#{@attachment.id}/download"}
      class="inline-flex items-center gap-3 break-all text-sm text-sky-700 hover:underline"
    >
      <%= if String.starts_with?(@attachment.content_type, "image/") do %>
        <img
          id={"attachment-thumbnail-#{@attachment.id}"}
          src={~p"/attachments/#{@attachment.id}/download"}
          alt={"Preview of #{@attachment.file_name}"}
          width="96"
          height="96"
          loading="lazy"
          decoding="async"
          class="size-24 shrink-0 rounded-lg border border-slate-200 bg-slate-50 object-contain"
        />
      <% else %>
        <.icon name="hero-paper-clip" class="size-4 shrink-0" />
      <% end %>
      {@attachment.file_name}
    </.link>
    """
  end
end
