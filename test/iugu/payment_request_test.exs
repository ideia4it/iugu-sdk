defmodule Iugu.PaymentRequestTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"
  @barcode "23700000000000000000000000000000000000000000000"

  test "validates a bank slip, pays it from the balance with a signed request that never retries, and reads the payment back" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/payment_requests/validate"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)
      assert body == %{"barcode" => @barcode, "detailed" => true}

      Req.Test.json(conn, %{
        "message" => "Boleto é válido",
        "payment_info" => %{
          "barcode" => @barcode,
          "amount_cents" => 8900,
          "fine_cents" => 178,
          "interest_cents" => 35,
          "discount_cents" => 0,
          "total_amount_cents" => 9113,
          "recipient_name" => "LOJISTA LTDA",
          "recipient_cnpj_cpf" => "12350768000171",
          "payer_name" => "NOME PAGADORA",
          "payer_cnpj_cpf" => "12345678900",
          "allow_amount_change" => false,
          "allow_partial_payment" => false,
          "due_date" => "2024-08-03",
          "maximum_payment_date" => "2024-09-23T00:00:00.000Z",
          "details" => "Retorno CIP  01 Boleto já baixado",
          "emitter" => "EMISSOR",
          "payee_cnpj_cpf" => "12345668000001"
        }
      })
    end)

    assert {:ok, validation} =
             Iugu.validate_payment_barcode(@barcode, api_token: @subaccount_token)

    assert validation.message == "Boleto é válido"

    assert %{
             barcode: @barcode,
             amount_cents: 8900,
             fine_cents: 178,
             interest_cents: 35,
             total_amount_cents: 9113,
             recipient_name: "LOJISTA LTDA",
             recipient_cpf_cnpj: "12350768000171",
             payer_cpf_cnpj: "12345678900",
             payee_cpf_cnpj: "12345668000001",
             allow_amount_change: false,
             due_date: "2024-08-03",
             details: "Retorno CIP  01 Boleto já baixado"
           } = validation.payment_info

    {private_key_pem, public_key} = generate_key_pair()

    expect_request_raw(fn conn, raw_body ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/v1/payment_requests"
      assert_basic(conn, @subaccount_token)
      assert conn.query_params == %{"api_token" => @subaccount_token}
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == []

      assert Jason.decode!(raw_body) == %{
               "barcode" => @barcode,
               "amount_cents" => 9113,
               "document_amount_cents" => 8900,
               "description" => "Conta de luz"
             }

      assert_signed(conn, raw_body, public_key, @subaccount_token)

      Req.Test.json(conn, %{
        "id" => "A1F7D3920C5B4E68A4729D1FE83BC047",
        "account_id" => "6B2E91CD7F0A4835B19C6D2E4A70F3D8",
        "barcode" => @barcode,
        "status" => "pending",
        "document_amount_cents" => 8900,
        "amount_cents" => 9113,
        "description" => "Conta de luz",
        "created_at" => "2026-06-24T12:32:21-03:00",
        "updated_at" => "2026-06-24T12:32:21-03:00",
        "receipt_url" => "https://comprovantes.iugu.com/a1f7d392",
        "payment_info" => %{"total_amount_cents" => 9113, "due_date" => "2026-06-25"}
      })
    end)

    assert {:ok, payment_request} =
             Iugu.create_payment_request(
               %{
                 barcode: @barcode,
                 amount_cents: 9113,
                 document_amount_cents: 8900,
                 description: "Conta de luz"
               },
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    assert %{
             id: "A1F7D3920C5B4E68A4729D1FE83BC047",
             account_id: "6B2E91CD7F0A4835B19C6D2E4A70F3D8",
             status: "pending",
             amount_cents: 9113,
             document_amount_cents: 8900,
             receipt_url: "https://comprovantes.iugu.com/a1f7d392",
             payment_info: %{total_amount_cents: 9113, due_date: "2026-06-25"}
           } = payment_request

    # No Idempotency-Key on this route, so a timeout is never retried: the
    # first attempt may already have paid the slip.
    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.create_payment_request(
               %{"barcode" => @barcode, "amount_cents" => 100, "document_amount_cents" => 100},
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    assert attempts() == 1

    # What the route would reject with 400 is refused here, without a call.
    assert {:error, %Error{kind: :validation, status: nil, messages: ["barcode é obrigatório."]}} =
             Iugu.create_payment_request(%{amount_cents: 100, document_amount_cents: 100},
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.create_payment_request(
               %{barcode: @barcode, amount_cents: 0, document_amount_cents: 100},
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    assert message =~ "amount_cents"

    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.create_payment_request(
               %{barcode: @barcode, amount_cents: 100, document_amount_cents: "100"},
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    assert message =~ "document_amount_cents"

    assert_raise ArgumentError, fn ->
      Iugu.create_payment_request(%{barcode: @barcode, amount: 100}, api_token: @subaccount_token)
    end

    assert {:error, %Error{kind: :validation, status: nil}} =
             Iugu.validate_payment_barcode("", api_token: @subaccount_token)

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/payment_requests/A1F7D3920C5B4E68A4729D1FE83BC047"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      Req.Test.json(conn, %{
        "id" => "A1F7D3920C5B4E68A4729D1FE83BC047",
        "status" => "done",
        "barcode" => @barcode,
        "amount_cents" => 9113,
        "document_amount_cents" => 8900,
        "receipt_url" => "https://comprovantes.iugu.com/a1f7d392",
        "payment_info" => nil
      })
    end)

    assert {:ok, %{status: "done", payment_info: nil, receipt_url: "https://" <> _url}} =
             Iugu.get_payment_request("A1F7D3920C5B4E68A4729D1FE83BC047",
               api_token: @subaccount_token
             )

    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(404)
      |> Req.Test.json(%{"errors" => "Payment request Not Found"})
    end)

    assert {:error, %Error{kind: :not_found, messages: ["Payment request Not Found"]}} =
             Iugu.get_payment_request("MISSING", api_token: @subaccount_token)
  end

  test "lists the account's payments by status, barcode and day, refuses an unknown status locally, and streams all pages" do
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/payment_requests"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      assert conn.query_params == %{
               "status" => "done",
               "barcode" => @barcode,
               "created_at_from" => "2026-09-01",
               "created_at_to" => "2026-09-30",
               "updated_at_from" => "2026-09-15",
               "limit" => "100"
             }

      # The reference shows a bare list, with no envelope and no total.
      Req.Test.json(conn, [
        %{
          "id" => "11334A9BBE5100DAC07C98DA3B9D2AD0",
          "account_id" => "A0A3672C83AE25A7E27A95E5758CEF79",
          "barcode" => @barcode,
          "status" => "done",
          "document_amount_cents" => 500,
          "amount_cents" => 500,
          "description" => nil,
          "created_at" => "2026-06-24T12:32:21-03:00",
          "updated_at" => "2026-06-24T12:44:30-03:00"
        }
      ])
    end)

    assert {:ok, page} =
             Iugu.list_payment_requests(
               status: "done",
               barcode: @barcode,
               created_at_from: ~D[2026-09-01],
               created_at_to: "2026-09-30",
               updated_at_from: ~D[2026-09-15],
               limit: 500,
               api_token: @subaccount_token
             )

    assert [
             %{
               id: "11334A9BBE5100DAC07C98DA3B9D2AD0",
               status: "done",
               amount_cents: 500,
               document_amount_cents: 500,
               description: nil,
               payment_info: nil
             }
           ] = page.payment_requests

    assert page.page_info == %{start: 0, limit: 100, total_items: nil}

    assert {:error, %Error{kind: :validation, status: nil, path: "/v1/payment_requests"}} =
             Iugu.list_payment_requests(status: "paid", api_token: @subaccount_token)

    Req.Test.expect(Iugu.Client, 2, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params do
        %{"start" => "0", "limit" => "2", "status" => "pending"} ->
          Req.Test.json(conn, [%{"id" => "1", "status" => "pending"}, %{"id" => "2"}])

        %{"start" => "2", "limit" => "2", "status" => "pending"} ->
          Req.Test.json(conn, [%{"id" => "3"}])
      end
    end)

    assert ["1", "2", "3"] =
             Iugu.stream_payment_requests(
               limit: 2,
               status: "pending",
               api_token: @subaccount_token
             )
             |> Enum.map(& &1.id)

    assert Iugu.payment_request_statuses() == ["pending", "processing", "rejected", "done"]
  end
end
