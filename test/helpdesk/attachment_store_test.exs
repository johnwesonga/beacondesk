defmodule Helpdesk.AttachmentStoreTest do
  use ExUnit.Case, async: false

  alias Helpdesk.AttachmentStore

  setup do
    variables = %{
      "BUCKET_NAME" => "test-bucket",
      "AWS_ACCESS_KEY_ID" => "test-key",
      "AWS_SECRET_ACCESS_KEY" => "test-secret"
    }

    previous = Map.new(variables, fn {key, _} -> {key, System.get_env(key)} end)
    System.put_env(variables)

    on_exit(fn ->
      Enum.each(previous, fn {key, value} ->
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end)
    end)
  end

  test "hashes stored binary bytes without decoding the response" do
    bytes = :binary.copy(<<0, 255, 128, 10>>, 100_000)

    Req.Test.stub(AttachmentStore, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path =~ "evidence.pdf"
      assert conn.query_string =~ "X-Amz-Signature="

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, bytes)
    end)

    expected = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    assert {:ok, ^expected} = AttachmentStore.checksum("evidence.pdf")
  end

  test "hashes empty files" do
    Req.Test.stub(AttachmentStore, &Plug.Conn.send_resp(&1, 200, ""))

    assert AttachmentStore.checksum("empty.pdf") ==
             {:ok, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}
  end

  test "does not hash error responses" do
    Req.Test.stub(AttachmentStore, &Plug.Conn.send_resp(&1, 403, "Access denied"))
    assert {:error, {:unexpected_status, 403}} = AttachmentStore.checksum("private.pdf")
  end

  test "returns transport failures" do
    Req.Test.stub(AttachmentStore, &Req.Test.transport_error(&1, :timeout))
    assert {:error, %Req.TransportError{reason: :timeout}} = AttachmentStore.checksum("file.pdf")
  end
end
