defmodule Iugu.TransferRequestTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error
  alias Iugu.TransferRequest

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"

  test "sends a Pix by key with a signed request, reads the id from transfer_request_id, never retries without a key and retries with one" do
    {private_key_pem, public_key} = generate_key_pair()

    expect_request_raw(fn conn, raw_body ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/v1/transfer_requests"
      assert_basic(conn, @subaccount_token)
      assert conn.query_params == %{"api_token" => @subaccount_token}
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == []

      assert Jason.decode!(raw_body) == %{
               "transfer_type" => "pix",
               "amount_cents" => 2,
               "description" => "transferência pix",
               "external_reference" => "00021",
               "receiver" => %{"pix" => %{"type" => "phone", "key" => "+5511999999999"}}
             }

      assert_signed(conn, raw_body, public_key, @subaccount_token)

      conn
      |> Plug.Conn.put_status(202)
      |> Req.Test.json(%{
        "transfer_request_id" => "0321A2977E7D4C199AF26AE5C74220EA",
        "created_at" => "2023-02-15T21:50:45-03:00",
        "amount_cents" => 2,
        "transfer_type" => "pix",
        "end_to_end_id" => "E1511197520230216005028cd18c6d3d",
        "external_reference" => "00021",
        "receipt_url" => "https://comprovantes.iugu.com/0321a297",
        "status" => "done"
      })
    end)

    assert {:ok, transfer_request} =
             Iugu.create_transfer_request(
               %{
                 transfer_type: "pix",
                 amount_cents: 2,
                 description: "transferência pix",
                 external_reference: "00021",
                 receiver: %{pix: %{type: "phone", key: "+5511999999999"}}
               },
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    assert %{
             id: "0321A2977E7D4C199AF26AE5C74220EA",
             status: "done",
             transfer_type: "pix",
             amount_cents: 2,
             end_to_end_id: "E1511197520230216005028cd18c6d3d",
             receipt_url: "https://comprovantes.iugu.com/0321a297"
           } = transfer_request

    # A done Pix is final on the spot.
    assert TransferRequest.final?(transfer_request)

    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.create_transfer_request(
               %{
                 transfer_type: "pix",
                 amount_cents: 2,
                 receiver: %{pix: %{type: "evp", key: "b6295ee1-f054-47d1-9e90-ee57b74f60d9"}}
               },
               api_token: @subaccount_token,
               signature_private_key: private_key_pem,
               retry: :transient,
               retry_delay: 0
             )

    assert attempts() == 1

    # With the key the timeout is retried once; the second attempt lands.
    test_pid = self()

    Req.Test.expect(Iugu.Client, 2, fn conn ->
      send(test_pid, :iugu_attempt)
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["pagamento-77"]
      assert Jason.decode!(raw_body)["scheduled_date"] == "2026-09-10"
      assert_signed(conn, raw_body, public_key, @subaccount_token)

      case attempts_so_far() do
        1 ->
          Req.Test.transport_error(conn, :timeout)

        _later ->
          Req.Test.json(conn, %{"transfer_request_id" => "SCHEDULED", "status" => "scheduled"})
      end
    end)

    assert {:ok, %{id: "SCHEDULED", status: "scheduled"} = scheduled} =
             Iugu.create_transfer_request(
               %{
                 transfer_type: "pix",
                 amount_cents: 1_000,
                 scheduled_date: ~D[2026-09-10],
                 receiver: %{pix: %{type: "email", key: "ana@loja.example"}}
               },
               idempotency_key: "pagamento-77",
               api_token: @subaccount_token,
               signature_private_key: private_key_pem,
               retry_delay: 0,
               retry_log_level: false
             )

    assert attempts() == 2
    refute TransferRequest.final?(scheduled)

    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{})
    end)

    assert {:error, %Error{kind: :validation, status: 409}} =
             Iugu.create_transfer_request(
               %{
                 transfer_type: "pix",
                 amount_cents: 1_000,
                 receiver: %{pix: %{type: "email", key: "ana@loja.example"}}
               },
               idempotency_key: "pagamento-77",
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )
  end

  test "sends a TED and an institutional transfer with bank data, and refuses locally each payload the route would reject with 400" do
    {private_key_pem, _public_key} = generate_key_pair()

    expect_request_raw(fn conn, raw_body ->
      assert conn.request_path == "/v1/transfer_requests"

      assert Jason.decode!(raw_body) == %{
               "transfer_type" => "ted",
               "amount_cents" => 2,
               "description" => "transferência ted",
               "external_reference" => "0001",
               "conciliation_id" => "B123D59000",
               "receiver" => %{
                 "name" => "Teste Teste",
                 "cpf_cnpj" => "12345678911",
                 "bank" => %{
                   "ispb" => "60701190",
                   "branch" => "1111",
                   "account" => "123456",
                   "account_type" => "checking_account"
                 }
               }
             }

      # The TED example in the docs is empty; a pending shape without the
      # end_to_end_id is what a TED can be expected to look like.
      Req.Test.json(conn, %{
        "transfer_request_id" => "TED",
        "amount_cents" => 2,
        "transfer_type" => "ted",
        "status" => "pending"
      })
    end)

    assert {:ok, %{id: "TED", status: "pending", end_to_end_id: nil} = ted} =
             Iugu.create_transfer_request(
               %{
                 "transfer_type" => "ted",
                 "amount_cents" => 2,
                 "description" => "transferência ted",
                 "external_reference" => "0001",
                 "conciliation_id" => "B123D59000",
                 "receiver" => %{
                   "name" => "Teste Teste",
                   "cpf_cnpj" => "12345678911",
                   "bank" => %{
                     "ispb" => "60701190",
                     "branch" => "1111",
                     "account" => "123456",
                     "account_type" => "checking_account"
                   }
                 }
               },
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    refute TransferRequest.final?(ted)

    # Institutional: ispb and branch only, plus hist and cit in the body; a
    # payment account needs no branch; compe stands in for ispb.
    expect_request_raw(fn conn, raw_body ->
      body = Jason.decode!(raw_body)
      assert body["transfer_type"] == "institucional"
      assert body["hist"] == "Pagamento de guia"
      assert body["cit"] == "123456"

      Req.Test.json(conn, %{"transfer_request_id" => "INST", "status" => "pending"})
    end)

    assert {:ok, %{id: "INST"}} =
             Iugu.create_transfer_request(
               %{
                 transfer_type: "institucional",
                 amount_cents: 10_000,
                 hist: "Pagamento de guia",
                 cit: "123456",
                 receiver: %{
                   name: "Tesouro",
                   cpf_cnpj: "00394460000141",
                   bank: %{ispb: "00000000", branch: "0001"}
                 }
               },
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    expect_request_raw(fn conn, raw_body ->
      assert Jason.decode!(raw_body)["receiver"]["bank"] == %{
               "compe" => "341",
               "account" => "19523074449",
               "account_type" => "payment_account"
             }

      Req.Test.json(conn, %{"transfer_request_id" => "PIX-ACCOUNT", "status" => "pending"})
    end)

    assert {:ok, %{id: "PIX-ACCOUNT"}} =
             Iugu.create_transfer_request(
               %{
                 transfer_type: "pix",
                 amount_cents: 500,
                 receiver: %{
                   name: "Teste Teste",
                   cpf_cnpj: "12345678911",
                   bank: %{compe: "341", account: "19523074449", account_type: "payment_account"}
                 }
               },
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    valid_ted = %{
      transfer_type: "ted",
      amount_cents: 200,
      receiver: %{
        name: "Teste Teste",
        cpf_cnpj: "12345678911",
        bank: %{
          ispb: "60701190",
          branch: "1111",
          account: "123456",
          account_type: "checking_account"
        }
      }
    }

    # Each of these is a 400 from Iugu. No stub is standing, so the refusal
    # is also proven to skip the network.
    refused = [
      {Map.put(valid_ted, :transfer_type, "tedi"), ~r/transfer_type/},
      {Map.put(valid_ted, :amount_cents, 1), ~r/amount_cents/},
      {Map.put(valid_ted, :amount_cents, 2.5), ~r/amount_cents/},
      {Map.delete(valid_ted, :receiver), ~r/receiver é obrigatório/},
      {put_in(valid_ted, [:receiver, :name], String.duplicate("a", 141)), ~r/140/},
      {update_in(valid_ted, [:receiver], &Map.delete(&1, :cpf_cnpj)), ~r/cpf_cnpj/},
      {update_in(valid_ted, [:receiver, :bank], &Map.delete(&1, :ispb)), ~r/ispb.*compe/},
      {put_in(valid_ted, [:receiver, :bank, :ispb], "6070119"), ~r/ispb/},
      {update_in(valid_ted, [:receiver, :bank], &Map.delete(&1, :branch)), ~r/branch/},
      {update_in(valid_ted, [:receiver, :bank], &Map.delete(&1, :account)), ~r/account é/},
      {put_in(valid_ted, [:receiver, :bank, :account_type], "corrente"), ~r/account_type/},
      {put_in(valid_ted, [:receiver, :pix], %{type: "cpf", key: "12345678911"}), ~r/pix só vale/},
      {Map.put(valid_ted, :conciliation_id, "B123-D59000"), ~r/conciliation_id/},
      {%{transfer_type: "pix", amount_cents: 2, receiver: %{pix: %{type: "cpf"}}}, ~r/pix.key/},
      {%{transfer_type: "pix", amount_cents: 2, receiver: %{pix: %{type: "chave", key: "x"}}},
       ~r/pix.type/},
      {%{
         transfer_type: "institucional",
         amount_cents: 2,
         hist: "h",
         receiver: valid_ted.receiver
       }, ~r/cit/}
    ]

    for {attrs, expected_message} <- refused do
      assert {:error,
              %Error{
                kind: :validation,
                status: nil,
                path: "/v1/transfer_requests",
                messages: [message]
              }} =
               Iugu.create_transfer_request(attrs,
                 api_token: @subaccount_token,
                 signature_private_key: private_key_pem
               )

      assert message =~ expected_message
    end

    assert_raise ArgumentError, ~r/splits/, fn ->
      Iugu.create_transfer_request(Map.put(valid_ted, :splits, []),
        api_token: @subaccount_token,
        signature_private_key: private_key_pem
      )
    end

    # Iugu's own refusals: a key nobody owns, a document mismatch, and the
    # five-second interval, in whatever status it arrives.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"errors" => "not found"})
    end)

    assert {:error, %Error{kind: :not_found}} =
             Iugu.create_transfer_request(
               %{
                 transfer_type: "pix",
                 amount_cents: 2,
                 receiver: %{pix: %{type: "cpf", key: "1"}}
               },
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{
        "errors" =>
          "Já existe uma transferência em processamento nesta conta. Espere a conclusão e tente novamente."
      })
    end)

    assert {:error, %Error{kind: :validation, status: 422, messages: [message]}} =
             Iugu.create_transfer_request(valid_ted,
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    assert message =~ "Espere a conclusão"
  end

  test "decodes a Pix QR code payload to see who gets paid and how much before sending the transfer" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/transfer_requests/decode_qrcode"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)
      assert body == %{"qrcode_payload" => "00020126580014br.gov.bcb.pix0136abc"}

      Req.Test.json(conn, %{
        "end_to_end_id" => "X12345678901234567890abcdef",
        "type" => "dynamic_qr_code",
        "qr_code" => %{
          "ispb" => 12_345_678,
          "receiver_key" => "abcdef12-3456-7890-abcd-ef1234567890",
          "receiver_key_type" => "evp",
          "receiver_name" => "João da Silva",
          "conciliation_id" => "BCDE1234567890ABCDE1234567890ABCDE",
          "amount" => 150,
          "qr_expires_in" => 133_318,
          "status" => "pending"
        }
      })
    end)

    assert {:ok, decoded} =
             Iugu.decode_pix_qrcode("00020126580014br.gov.bcb.pix0136abc",
               api_token: @subaccount_token
             )

    assert %{
             type: "dynamic_qr_code",
             end_to_end_id: "X12345678901234567890abcdef",
             qr_code: %{
               "receiver_name" => "João da Silva",
               "amount" => 150,
               "status" => "pending"
             }
           } = decoded

    # A lookup moves no money, so a dropped connection is retried.
    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.decode_pix_qrcode("00020126580014br.gov.bcb.pix0136abc",
               api_token: @subaccount_token,
               retry_delay: 0,
               retry_log_level: false
             )

    assert attempts() > 1

    assert {:error, %Error{kind: :validation, status: nil}} =
             Iugu.decode_pix_qrcode("", api_token: @subaccount_token)
  end

  test "follows a transfer: reads the receipt in both documented shapes, applies the 24 hour TED rule, lists with sorting and dates, and cancels a scheduled Pix" do
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/transfer_requests/000016C4DAF14A89A271D3D341B352B7"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      Req.Test.json(conn, %{
        "id" => "000016C4DAF14A89A271D3D341B352B7",
        "status" => "done",
        "transfer_type" => "ted",
        "description" => nil,
        "external_reference" => nil,
        "created_at" => "2022-10-22T03:39:28-03:00",
        "updated_at" => "2022-10-22T03:39:32-03:00",
        "amount_cents" => 1940,
        "end_to_end_id" => nil,
        "amount" => "19.40 BRL",
        "executed_at" => "2022-10-22T03:39:32-03:00",
        "rejected_at" => nil,
        "rejected_reason" => nil,
        "receipt_url" => "https://comprovantes.iugu.com/000016C4-hed1",
        "sender_account" => %{"id" => "SENDER", "cpf_cnpj" => "***117.192/0001-**"},
        "receiver_account" => %{"name" => "Teste Teste", "bank_account" => "19523074449"}
      })
    end)

    assert {:ok, ted} =
             Iugu.get_transfer_request("000016C4DAF14A89A271D3D341B352B7",
               api_token: @subaccount_token
             )

    assert %{
             id: "000016C4DAF14A89A271D3D341B352B7",
             status: "done",
             transfer_type: "ted",
             amount_cents: 1940,
             executed_at: "2022-10-22T03:39:32-03:00",
             rejected_reason: nil,
             receipt_url: "https://comprovantes.iugu.com/000016C4-hed1",
             sender_account: %{"id" => "SENDER"},
             receiver_account: %{"bank_account" => "19523074449"}
           } = ted

    # A TED in done can still bounce for 24 hours after execution.
    refute TransferRequest.final?(ted, ~U[2022-10-23 06:00:00Z])
    assert TransferRequest.final?(ted, ~U[2022-10-23 07:00:00Z])
    assert TransferRequest.final?(ted)

    # The older documented shape: "reson", "updated", "0,02 BRL".
    Req.Test.expect(Iugu.Client, fn conn ->
      Req.Test.json(conn, %{
        "id" => "OLD",
        "status" => "rejected",
        "transfer_type" => "ted",
        "amount" => "0,02 BRL",
        "amount_cents" => "2",
        "reson" => "2 - Agência ou Conta Destinatária do Crédito Inválida",
        "updated" => "2024-06-14T10:11:03-03:00"
      })
    end)

    assert {:ok,
            %{
              id: "OLD",
              amount_cents: 2,
              rejected_reason: "2 - Agência ou Conta Destinatária do Crédito Inválida",
              updated_at: "2024-06-14T10:11:03-03:00"
            } = rejected} = Iugu.get_transfer_request("OLD", api_token: @subaccount_token)

    assert TransferRequest.final?(rejected)

    # A raw webhook-like map with string keys is accepted by final?/2 too;
    # a done TED without a readable date is not final.
    refute TransferRequest.final?(%{"status" => "done", "transfer_type" => "ted"})
    assert TransferRequest.final?(%{"status" => "cancelled"})

    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(404)
      |> Req.Test.json(%{"errors" => "Transferência não encontrada"})
    end)

    assert {:error, %Error{kind: :not_found, messages: ["Transferência não encontrada"]}} =
             Iugu.get_transfer_request("MISSING", api_token: @subaccount_token)

    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      # The reference documents the listing with a trailing slash.
      assert conn.request_path == "/v1/transfer_requests/"
      assert_basic(conn, @subaccount_token)

      assert conn.query_params == %{
               "start" => "100",
               "limit" => "100",
               "query" => "ana@loja.example",
               "sortby" => "executed_at",
               "updated_at_from" => "2026-09-01",
               "updated_at_to" => "2026-09-30T20:59:59-03:00"
             }

      Req.Test.json(conn, %{
        "totalItems" => 101,
        "items" => [%{"id" => "A", "status" => "done", "amount_cents" => 100}]
      })
    end)

    assert {:ok,
            %{
              transfer_requests: [%{id: "A", status: "done", amount_cents: 100}],
              page_info: %{start: 100, limit: 100, total_items: 101}
            }} =
             Iugu.list_transfer_requests(
               start: 100,
               limit: 1_000,
               query: "ana@loja.example",
               sort_by: "executed_at",
               updated_at_from: ~D[2026-09-01],
               updated_at_to: ~U[2026-09-30 23:59:59Z],
               api_token: @subaccount_token
             )

    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.list_transfer_requests(sort_by: "created_at", api_token: @subaccount_token)

    assert message =~ "sort_by"

    # The stream walks the pages and stops on the short one, never trusting
    # totalItems.
    Req.Test.expect(Iugu.Client, 2, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params do
        %{"start" => "0", "limit" => "2"} ->
          Req.Test.json(conn, %{"totalItems" => 999, "items" => [%{"id" => "1"}, %{"id" => "2"}]})

        %{"start" => "2", "limit" => "2"} ->
          Req.Test.json(conn, %{"totalItems" => 999, "items" => [%{"id" => "3"}]})
      end
    end)

    assert ["1", "2", "3"] =
             Iugu.stream_transfer_requests(limit: 2, api_token: @subaccount_token)
             |> Enum.map(& &1.id)

    expect_request_raw(fn conn, raw_body ->
      assert conn.method == "PATCH"

      assert conn.request_path ==
               "/v1/transfer_requests/E2483B68CA624DC98A88AFC7D1565213/scheduled_cancel"

      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)
      assert raw_body == ""

      Req.Test.json(conn, %{
        "transfer_request_id" => "E2483B68CA624DC98A88AFC7D1565213",
        "created_at" => "2025-02-11T11:28:08-03:00",
        "amount_cents" => 10,
        "transfer_type" => "pix",
        "end_to_end_id" => "E151119752025021114280e7d38e1745",
        "external_reference" => nil,
        "receipt_url" => "https://comprovantes.iugu.test/e2483b68",
        "status" => "cancelled"
      })
    end)

    assert {:ok, %{id: "E2483B68CA624DC98A88AFC7D1565213", status: "cancelled"} = cancelled} =
             Iugu.cancel_scheduled_transfer_request("E2483B68CA624DC98A88AFC7D1565213",
               api_token: @subaccount_token
             )

    assert TransferRequest.final?(cancelled)

    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"errors" => "Transfer status must be scheduled."})
    end)

    assert {:error, %Error{kind: :validation, messages: ["Transfer status must be scheduled."]}} =
             Iugu.cancel_scheduled_transfer_request("E2483B68CA624DC98A88AFC7D1565213",
               api_token: @subaccount_token
             )

    assert Iugu.transfer_request_types() == ["ted", "pix", "institucional"]
    assert Iugu.pix_key_types() == ["cpf", "cnpj", "email", "phone", "evp"]
    assert "payment_account" in Iugu.transfer_request_account_types()
    assert "partially_refunded" in Iugu.transfer_request_statuses()
  end
end
