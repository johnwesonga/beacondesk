defmodule HelpdeskWeb.AttachmentUpload do
  use HelpdeskWeb, :html

  attr :upload, :any, required: true
  attr :label, :string, default: "Add ticket attachments"
  attr :cancel_event, :string, default: "cancel-upload"

  def picker(assigns) do
    ~H"""
    <label for={@upload.ref} class="mb-2 block font-semibold">
      {@label}
    </label>
    <.live_file_input upload={@upload} class="file-input w-full" />
    <p class="mt-2 text-xs text-slate-500">
      Up to {@upload.max_entries} files: PNG, JPEG, WebP, PDF or DOC.
    </p>
    <div
      :for={entry <- @upload.entries}
      id={"pending-#{entry.ref}"}
      class="mt-3 text-sm"
    >
      <span>{entry.client_name} · {entry.progress}%</span>
      <progress
        value={entry.progress}
        max="100"
        class="progress"
        aria-label={"Uploading #{entry.client_name}"}
      >
      </progress>
      <p :for={error <- upload_errors(@upload, entry)} class="text-error">
        {upload_error(error)}
      </p>
      <button
        type="button"
        phx-click={@cancel_event}
        phx-value-ref={entry.ref}
        class="btn btn-xs btn-ghost"
      >
        Remove
      </button>
    </div>
    <p :for={error <- upload_errors(@upload)} class="text-sm text-error">
      {upload_error(error)}
    </p>
    """
  end

  defp upload_error(:too_large), do: "File exceeds the upload size limit."
  defp upload_error(:too_many_files), do: "Select no more than three files."
  defp upload_error(:not_accepted), do: "This file type is not supported."
  defp upload_error(_), do: "Upload failed. Remove the file and try again."
end
