defmodule Helpdesk.SimpleS3UploadTest do
  use ExUnit.Case, async: true
  alias Helpdesk.SimpleS3Upload

  @config %{region: "auto", access_key_id: "test-key", secret_access_key: "test-secret"}
  @options [
    key: "attachments/test.png",
    content_type: "image/png",
    max_file_size: 10_000,
    expires_in: 3_600_000
  ]
  @now ~U[2026-09-08 23:30:00Z]

  test "signs with today's date even when expiration falls tomorrow" do
    {:ok, fields} = SimpleS3Upload.sign_form_upload(@config, "test-bucket", @options, @now)
    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()
    assert fields["x-amz-date"] == "20260908T233000Z"
    assert fields["x-amz-credential"] == "test-key/20260908/auto/s3/aws4_request"
    assert policy["expiration"] == "2026-09-09T00:30:00.000Z"
    assert ["content-length-range", 1, 10_000] in policy["conditions"]
    assert ["eq", "$Content-Type", fields["Content-Type"]] in policy["conditions"]
    # Independently calculated with Python's hmac/hashlib using this fixed policy.
    assert fields["x-amz-signature"] ==
             "984d3a9c8acda7e264431915da43eabcb929fc402f15122df3651d0855f65109"
  end

  test "encodes quotes and backslashes without changing the object key" do
    key = "attachments/a\"b\\c.png"

    {:ok, fields} =
      SimpleS3Upload.sign_form_upload(
        @config,
        "test-bucket",
        Keyword.put(@options, :key, key),
        @now
      )

    policy = fields["policy"] |> Base.decode64!() |> Jason.decode!()
    assert ["eq", "$key", key] in policy["conditions"]
    assert fields["key"] == key
  end

  test "requires positive integer limits" do
    for option <- [:max_file_size, :expires_in], value <- [0, -1, nil, 1.5, "100"] do
      assert_raise ArgumentError, "#{option} must be a positive integer", fn ->
        SimpleS3Upload.sign_form_upload(
          @config,
          "test-bucket",
          Keyword.put(@options, option, value),
          @now
        )
      end
    end
  end
end
