defmodule Iugu.TransferTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"
  @master_id "27016E1AD888499A98994E781B6C3762"
  @subaccount_id "0D16C52DD91F413BACFA24FD6868B18A"

  test "subaccount pays the master its withdraw fee with a signed transfer that never retries, then the master pays a subaccount with an idempotency key that turns the retry on" do
    {private_key_pem, public_key} = generate_key_pair()

    expect_request_raw(fn conn, raw_body ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/v1/transfers"
      # Whitelabel: the master's key signs, the subaccount (the account being
      # debited) authenticates and sits on line 2 of the signed document.
      assert_basic(conn, @subaccount_token)
      assert conn.query_params == %{"api_token" => @subaccount_token}
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == []
      assert raw_body == ~s({"amount_cents":100,"receiver_id":"#{@master_id}"})
      assert_signed(conn, raw_body, public_key, @subaccount_token)

      Req.Test.json(conn, %{
        "id" => "7839481C235A47C088987FE94360E9BD",
        "created_at" => "2024-04-29T10:16:34-03:00",
        "amount_cents" => 100,
        "amount_localized" => "R$ 1,00",
        "updated_at" => "2024-04-29T10:16:34-03:00",
        "receiver" => %{"id" => @master_id, "name" => "Matriz"},
        "sender" => %{"id" => @subaccount_id, "name" => "Loja Ana"},
        "custom_variables" => []
      })
    end)

    assert {:ok, transfer} =
             Iugu.create_transfer(@master_id, 100,
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    assert %{
             id: "7839481C235A47C088987FE94360E9BD",
             amount_cents: 100,
             amount_localized: "R$ 1,00",
             receiver: %{id: @master_id, name: "Matriz"},
             sender: %{id: @subaccount_id, name: "Loja Ana"},
             custom_variables: [],
             created_at: "2024-04-29T10:16:34-03:00"
           } = transfer

    assert transfer.body["updated_at"] == "2024-04-29T10:16:34-03:00"

    # Without a key a timeout may have debited the sender, so even an
    # explicit retry option is ignored.
    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.create_transfer(@master_id, 100,
               api_token: @subaccount_token,
               signature_private_key: private_key_pem,
               retry: :transient,
               retry_delay: 0
             )

    assert attempts() == 1

    # The master pays a subaccount with the default token; the key makes the
    # POST safe to repeat, so the transient failure is retried and the
    # second attempt succeeds, each one signed afresh.
    test_pid = self()

    Req.Test.expect(Iugu.Client, 2, fn conn ->
      send(test_pid, :iugu_attempt)
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

      assert_basic(conn, "iugu-test-token")
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["repasse-2026-09"]

      assert Jason.decode!(raw_body) == %{
               "receiver_id" => @subaccount_id,
               "amount_cents" => 4_500,
               "custom_variables" => [%{"name" => "origem", "value" => "repasse"}]
             }

      assert_signed(conn, raw_body, public_key, "iugu-test-token")

      case attempts_so_far() do
        1 -> Req.Test.transport_error(conn, :timeout)
        _later -> Req.Test.json(conn, %{"id" => "TRANSFER", "amount_cents" => 4_500})
      end
    end)

    assert {:ok, %{id: "TRANSFER", amount_cents: 4_500, sender: nil, receiver: nil}} =
             Iugu.create_transfer(@subaccount_id, 4_500,
               custom_variables: [%{name: "origem", value: "repasse"}],
               idempotency_key: "repasse-2026-09",
               signature_private_key: private_key_pem,
               retry_delay: 0,
               retry_log_level: false
             )

    assert attempts() == 2

    # Below one cent and without a receiver nothing leaves the process.
    assert {:error, %Error{kind: :validation, status: nil, path: "/v1/transfers"}} =
             Iugu.create_transfer(@master_id, 0,
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    assert {:error,
            %Error{kind: :validation, status: nil, messages: ["receiver_id é obrigatório."]}} =
             Iugu.create_transfer("", 100,
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    # This route's 422 uses "message", not "errors"; it reads like the
    # "errors" map, so the caller sees the field without opening the body.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"message" => %{"amount_cents" => ["Saldo insuficiente"]}})
    end)

    assert {:error,
            %Error{
              kind: :validation,
              status: 422,
              messages: ["amount_cents: Saldo insuficiente"],
              fields: %{"amount_cents" => ["Saldo insuficiente"]},
              body: %{"message" => %{"amount_cents" => ["Saldo insuficiente"]}}
            }} =
             Iugu.create_transfer(@master_id, 1_000_000,
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{})
    end)

    assert {:error, %Error{kind: :validation, status: 409}} =
             Iugu.create_transfer(@subaccount_id, 4_500,
               idempotency_key: "repasse-2026-09",
               signature_private_key: private_key_pem
             )
  end

  test "lists what the account sent and received, with the filters in Iugu's formats, and refuses an unknown transfer type locally" do
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/transfers"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      assert conn.query_params == %{
               "start" => "0",
               "limit" => "100",
               "transfer_type" => "debit_transfer",
               "custom_variables_name" => "origem",
               "custom_variables_value" => "repasse",
               # A DateTime lands in São Paulo time; a Date goes as a date.
               "created_at_from" => "2026-09-01T00:00:00-03:00",
               "created_at_to" => "2026-09-30"
             }

      Req.Test.json(conn, %{
        "sent" => [
          %{
            "id" => "SENT",
            "created_at" => "2013-11-19T11:24:29-02:00",
            "amount_cents" => "1000",
            "amount_localized" => "R$ 10,00",
            "receiver" => %{"id" => @master_id, "name" => "Matriz"}
          }
        ],
        "received" => [
          %{
            "id" => "RECEIVED",
            "created_at" => "2013-12-19T11:24:29-02:00",
            "amount_cents" => "2000",
            "amount_localized" => "R$ 20,00",
            "sender" => %{"id" => @master_id, "name" => "Matriz"}
          }
        ]
      })
    end)

    assert {:ok, page} =
             Iugu.list_transfers(
               start: 0,
               limit: 500,
               transfer_type: "debit_transfer",
               custom_variables_name: "origem",
               custom_variables_value: "repasse",
               created_at_from: ~U[2026-09-01 03:00:00Z],
               created_at_to: ~D[2026-09-30],
               api_token: @subaccount_token
             )

    # amount_cents is a string on this route and an integer to the caller.
    assert [%{id: "SENT", amount_cents: 1_000, receiver: %{id: @master_id}, sender: nil}] =
             page.sent

    assert [%{id: "RECEIVED", amount_cents: 2_000, sender: %{name: "Matriz"}, receiver: nil}] =
             page.received

    assert page.page_info == %{start: 0, limit: 100, total_items: nil}

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.query_string == ""

      Req.Test.json(conn, %{"sent" => [], "received" => []})
    end)

    assert {:ok, %{sent: [], received: [], page_info: %{start: 0, limit: nil}}} =
             Iugu.list_transfers()

    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.list_transfers(transfer_type: "pix")

    assert message =~ "transfer_type"

    assert Iugu.transfer_types() == [
             "account_requested",
             "internal_transfer",
             "mirror",
             "debit_transfer"
           ]
  end
end
