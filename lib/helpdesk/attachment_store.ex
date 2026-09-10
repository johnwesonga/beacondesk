defmodule Helpdesk.AttachmentStore do
  alias Helpdesk.SimpleS3Upload

  @presigned_url_default_options [
    expires_in: 3600
  ]

  def bucket, do: System.fetch_env!("BUCKET_NAME")
  def host, do: System.fetch_env!("AWS_ENDPOINT_URL_S3")

  def s3_filepath(entry) do
    "#{entry.uuid}.#{ext(entry)}"
  end

  def ext(entry) do
    [ext | _] = MIME.extensions(entry.client_type)
    ext
  end

  def key(attachment, :original) do
    Path.join(["attachments", attachment.id])
  end

  def entry_url(entry) do
    "#{String.trim_trailing(host(), "/")}/#{bucket()}/#{s3_filepath(entry)}"
  end

  def presigned_download_url(attachment, opts \\ []) do
    opts = Keyword.merge(@presigned_url_default_options, opts)
    attachment_entry = attachment.storage_key

    {:ok, url} =
      ExAws.Config.new(:s3)
      |> ExAws.S3.presigned_url(:get, bucket(), attachment_entry, opts)

    url
  end

  def presigned_upload_form_url(entry, max_file_size) do
    bucket = bucket()
    s3_filepath = s3_filepath(entry)

    config = %{
      region: System.get_env("AWS_REGION", "auto"),
      access_key_id: System.fetch_env!("AWS_ACCESS_KEY_ID"),
      secret_access_key: System.fetch_env!("AWS_SECRET_ACCESS_KEY")
    }

    {:ok, fields} =
      SimpleS3Upload.sign_form_upload(config, bucket,
        key: s3_filepath,
        content_type: entry.client_type,
        max_file_size: max_file_size,
        expires_in: :timer.hours(1)
      )

    host = Application.get_env(:ex_aws, :s3) |> Keyword.fetch!(:host)
    url = "https://#{bucket}.#{host}"

    %{
      uploader: "Tigris",
      key: s3_filepath,
      url: url,
      fields: fields
    }
  end
end
