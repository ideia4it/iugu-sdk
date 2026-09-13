defmodule Iugu.ClientTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Client
  alias Iugu.Error

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  test "builds a client with Basic auth of the token and an empty password, letting the caller override token and endpoint" do
    # The docs: "Codificar a chave API, junto com o caracter ':' no final da
    # chave, para o formato Base64", and their own worked example.
    assert authorization(Client.new()) == "Basic " <> Base.encode64("iugu-test-token:")

    documented_token = "5AA555555555555555555555555555555CC55555555555555555555555555DD5"

    assert authorization(Client.new(api_token: documented_token)) ==
             "Basic NUFBNTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1Q0M1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NTU1NURENTo="

    # POST /v1/payment_token is the one route documented without a token;
    # there the header stays out instead of carrying the master's token.
    refute Map.has_key?(Client.new(api_token: :none).headers, "authorization")

    assert Client.new().options.base_url == "https://api.iugu.com"

    # The merge order is easy to write backwards. Reversed, the day
    # :req_options grows a second key it starts silently discarding
    # what the caller asked for.
    assert Client.new(base_url: "https://iugu.example.test").options.base_url ==
             "https://iugu.example.test"
  end

  test "maps every Iugu answer onto a result: any 2xx body, a non 2xx error with status, fields and path, and a retriable transport error" do
    for status <- [200, 201, 204] do
      Req.Test.stub(Iugu.Client, fn conn ->
        conn |> Plug.Conn.put_status(status) |> Req.Test.json(%{"ok" => true})
      end)

      assert {:ok, %{"ok" => true}} = Client.get("/v1/accounts/ACC")
    end

    # A subaccount call reaches Iugu with that subaccount's token, since the
    # master token gets a 401 on anything the subaccount owns.
    Req.Test.expect(Iugu.Client, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("SUBACCOUNT-TOKEN:")
             ]

      Req.Test.json(conn, %{"id" => "ACC"})
    end)

    assert {:ok, %{"id" => "ACC"}} = Client.get("/v1/accounts/ACC", api_token: "SUBACCOUNT-TOKEN")

    # How each status maps onto a kind belongs to Iugu.Error and is
    # covered there; what the client owns is feeding it the response and the
    # route the log has to point at.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"errors" => "Unauthorized"})
    end)

    assert {:error,
            %Error{
              kind: :unauthorized,
              status: 401,
              path: "/v1/accounts/ACC",
              messages: ["Unauthorized"]
            }} = Client.get("/v1/accounts/ACC")

    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"errors" => %{"due_date" => ["não pode ficar em branco"]}})
    end)

    assert {:error,
            %Error{kind: :validation, fields: %{"due_date" => ["não pode ficar em branco"]}}} =
             Client.post("/v1/invoices", %{})

    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
    end)

    assert {:error, %Error{kind: :server, path: "/v1/accounts/ACC/request_withdraw"}} =
             Client.put("/v1/accounts/ACC/request_withdraw", %{})

    Req.Test.stub(Iugu.Client, &Req.Test.transport_error(&1, :econnrefused))

    assert {:error, %Error{kind: :transport, path: "/v1/accounts/ACC"} = error} =
             Client.get("/v1/accounts/ACC", retry: false)

    assert Error.retriable?(error)
  end

  test "sends the verb and JSON body of each write and escapes a path segment that would otherwise change the route" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/customers"
      assert body == %{"email" => "ana@loja.com", "name" => "Ana"}

      Req.Test.json(conn, %{"id" => "CUS"})
    end)

    assert {:ok, %{"id" => "CUS"}} =
             Client.post("/v1/customers", %{email: "ana@loja.com", name: "Ana"})

    expect_request(fn conn, body ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/payments/pix"
      assert body == %{"enable" => true}

      Req.Test.json(conn, %{"success" => true})
    end)

    assert {:ok, %{"success" => true}} = Client.put("/v1/payments/pix", %{enable: true})

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/customers/CUS"

      Req.Test.json(conn, %{"id" => "CUS"})
    end)

    assert {:ok, %{"id" => "CUS"}} = Client.delete("/v1/customers/CUS")

    assert Client.encode_path_segment("pedido/2024+01@loja") == "pedido%2F2024%2B01%40loja"
  end

  test "retries a read, never retries a write, and retries a write only when the caller asks for :transient" do
    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Client.get("/v1/invoices", retry_delay: 0, max_retries: 1, retry_log_level: false)

    assert attempts() == 2

    # A withdraw takes no Idempotency-Key, so a retry after a timeout can
    # produce a second withdrawal.
    for write <- [
          fn -> Client.post("/v1/accounts/ACC/request_withdraw", %{amount: 5.0}) end,
          fn -> Client.put("/v1/accounts/ACC", %{website: "https://loja.example"}) end,
          fn -> Client.delete("/v1/ACC/api_tokens/TOKEN") end
        ] do
      stub_counting_transport_error()

      assert {:error, %Error{kind: :transport}} = write.()
      assert attempts() == 1
    end

    # :safe_transient would NOT do it: it treats only GET and HEAD as safe, so
    # on a POST it retries 429 and 503 and lets the timeout through.
    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Client.post("/v1/invoices", %{},
               retry: :transient,
               retry_delay: 0,
               max_retries: 1,
               retry_log_level: false
             )

    assert attempts() == 2
  end

  test "proves the RSA routine against Iugu before the first cash-out, reading the verdict back and never retrying" do
    {private_key_pem, public_key} = generate_key_pair()

    expect_request_raw(fn conn, raw_body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/signature/validate"
      assert raw_body == ~s({"RAW_BODY":"iugu dry run"})
      assert_basic(conn, "iugu-test-token")
      assert_signed(conn, raw_body, public_key, "iugu-test-token")

      Req.Test.json(conn, %{
        "message" => "Signature check successful",
        "request_body" => raw_body,
        "status" => "ok"
      })
    end)

    assert {:ok,
            %{
              message: "Signature check successful",
              request_body: ~s({"RAW_BODY":"iugu dry run"}),
              status: "ok"
            }} =
             Iugu.validate_signature("iugu dry run", signature_private_key: private_key_pem)

    # A key Iugu does not know is the same 422 a withdraw would get later,
    # now with nothing at stake.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"errors" => "Public Key Not Found"})
    end)

    assert {:error, %Error{kind: :validation, status: 422, messages: ["Public Key Not Found"]}} =
             Iugu.validate_signature("iugu dry run", signature_private_key: private_key_pem)

    # The route takes no Idempotency-Key, so it is never retried.
    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.validate_signature("iugu dry run",
               signature_private_key: private_key_pem,
               retry: :transient
             )

    assert attempts() == 1
  end

  test "signs a request over the exact bytes it sends, with the path without the query and the token both in the header and in the query" do
    {private_key_pem, public_key} = generate_key_pair()

    expect_request_raw(fn conn, raw_body ->
      conn = Plug.Conn.fetch_query_params(conn)

      # The signed path carries /v1 and no query; the query carries the token
      # the way every official recipe does, and Basic auth stays as well.
      assert conn.request_path == "/v1/marketplace/create_account"
      assert conn.query_params == %{"api_token" => "iugu-test-token", "debug" => "1"}

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("iugu-test-token:")
             ]

      assert Plug.Conn.get_req_header(conn, "content-type") == ["application/json"]
      assert Plug.Conn.get_req_header(conn, "x-signature-token-id") == ["TOKEN-ID"]

      [request_time] = Plug.Conn.get_req_header(conn, "request-time")
      ["signature=" <> encoded_signature] = Plug.Conn.get_req_header(conn, "signature")

      # ISO 8601 at seconds precision, generated right before sending: Iugu
      # gives five minutes from Request-Time.
      assert {:ok, sent_at, 0} = DateTime.from_iso8601(request_time)
      assert DateTime.diff(DateTime.utc_now(), sent_at) in 0..5
      refute request_time =~ "."

      # The body on the wire is compact JSON, and it is what was signed.
      assert raw_body == ~s({"name":"Loja Ana"})

      content =
        "POST|/v1/marketplace/create_account\niugu-test-token|#{request_time}\n#{raw_body}"

      assert :public_key.verify(content, :sha256, Base.decode64!(encoded_signature), public_key)

      Req.Test.json(conn, %{"account_id" => "ACC"})
    end)

    assert {:ok, %{"account_id" => "ACC"}} =
             Client.post("/v1/marketplace/create_account", %{name: "Loja Ana"},
               sign: true,
               signature_private_key: private_key_pem,
               signature_token_id: "TOKEN-ID",
               params: [debug: 1]
             )

    # Whitelabel flow: the master's key signs, but line 2 and the request
    # carry the subaccount's own token. Without a token id the header is
    # simply absent. A GET signs an empty third line and sends no body.
    expect_request_raw(fn conn, raw_body ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert raw_body == ""
      assert conn.query_params == %{"api_token" => "SUBACCOUNT-TOKEN"}
      assert Plug.Conn.get_req_header(conn, "x-signature-token-id") == []

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("SUBACCOUNT-TOKEN:")
             ]

      [request_time] = Plug.Conn.get_req_header(conn, "request-time")
      ["signature=" <> encoded_signature] = Plug.Conn.get_req_header(conn, "signature")

      content = "GET|/v1/MASTER/api_tokens\nSUBACCOUNT-TOKEN|#{request_time}\n"

      assert :public_key.verify(content, :sha256, Base.decode64!(encoded_signature), public_key)

      Req.Test.json(conn, %{"accounts" => %{}})
    end)

    assert {:ok, %{"accounts" => %{}}} =
             Client.get("/v1/MASTER/api_tokens",
               sign: true,
               api_token: "SUBACCOUNT-TOKEN",
               signature_private_key: private_key_pem
             )

    # An unsigned call carries none of it, so a route that does not expect
    # the headers never sees them.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.query_params == %{}
      assert Plug.Conn.get_req_header(conn, "signature") == []
      assert Plug.Conn.get_req_header(conn, "request-time") == []

      Req.Test.json(conn, %{})
    end)

    assert {:ok, %{}} = Client.get("/v1/marketplace")

    # And asking for a signature without a key fails before any request goes
    # out, pointing at the config instead of at a 422 from Iugu.
    assert_raise RuntimeError, ~r/IUGU_SIGNATURE_PRIVATE_KEY/, fn ->
      Client.post("/v1/transfers", %{}, sign: true)
    end
  end

  defp authorization(%Req.Request{headers: headers}) do
    headers |> Map.get("authorization", []) |> List.first()
  end
end
