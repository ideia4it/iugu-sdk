defmodule Iugu.InvoiceTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error
  alias Iugu.Split

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"

  test "creates an invoice as the subaccount with the documented conversions, retries only when an idempotency key makes it safe, and refuses before the call what Iugu would reject" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/invoices"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == []

      assert body == %{
               "email" => "cliente@exemplo.com",
               "cc_emails" => "financeiro@loja.com, dono@loja.com",
               "due_date" => "2026-09-16",
               "expires_in" => "5",
               "bank_slip_extra_due" => "3",
               "items" => [
                 %{"description" => "Corte", "quantity" => 1, "price_cents" => 8_000},
                 %{"description" => "Escova", "quantity" => 2, "price_cents" => 1_500}
               ],
               "payable_with" => ["pix", "bank_slip"],
               "payer" => %{"cpf_cnpj" => "113.436.750-30", "name" => "Nome do Pagador"},
               "splits" => [
                 %{"recipient_account_id" => "MASTER", "percent" => 10},
                 %{"recipient_account_id" => "PRO", "cents" => 3_000}
               ],
               "discount_cents" => 1_000,
               "external_reference" => "atendimento-42",
               "order_id" => "pedido-42",
               "notification_url" => "https://example.com/webhooks/iugu",
               "fines" => true,
               "late_payment_fine" => 2,
               "custom_variables" => [%{"name" => "origem", "value" => "meu-app"}],
               "pix_qr_code_expires_at" => "2026-09-16T23:59:59-00:00",
               "ignore_due_email" => true
             }

      Req.Test.json(conn, invoice_body(%{"status" => "pending"}))
    end)

    assert {:ok, %{"id" => "EBB161AAB22849BFA047D5F1DF55AEE9", "status" => "pending"}} =
             Iugu.create_invoice(
               %{
                 email: "cliente@exemplo.com",
                 cc_emails: ["financeiro@loja.com", "dono@loja.com"],
                 due_date: ~D[2026-09-16],
                 expires_in: 5,
                 bank_slip_extra_due: 3,
                 items: [
                   %{description: "Corte", quantity: 1, price_cents: 8_000},
                   %{"description" => "Escova", "quantity" => 2, "price_cents" => 1_500}
                 ],
                 payable_with: [:pix, "bank_slip"],
                 payer: %{cpf_cnpj: "113.436.750-30", name: "Nome do Pagador"},
                 splits: [Split.percent("MASTER", 10), Split.fixed("PRO", 3_000)],
                 discount_cents: 1_000,
                 external_reference: "atendimento-42",
                 order_id: "pedido-42",
                 notification_url: "https://example.com/webhooks/iugu",
                 fines: true,
                 late_payment_fine: 2,
                 custom_variables: [%{name: "origem", value: "meu-app"}],
                 pix_qr_code_expires_at: ~U[2026-09-16 23:59:59Z],
                 ignore_due_email: true
               },
               api_token: @subaccount_token
             )

    # With the key the header goes out and a timeout is retried, because the
    # second attempt cannot create a second invoice.
    Req.Test.expect(Iugu.Client, fn conn ->
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["atendimento-42"]
      Req.Test.transport_error(conn, :timeout)
    end)

    expect_request(fn conn, body ->
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["atendimento-42"]
      # customer_id stands in for email; expires_in may be a date, as one
      # official guide does.
      assert body == %{
               "customer_id" => "CUS",
               "due_date" => "2026-09-26",
               "expires_in" => "2026-09-30",
               "items" => [%{"description" => "Corte", "quantity" => 1, "price_cents" => 8_000}]
             }

      Req.Test.json(conn, invoice_body(%{"status" => "pending"}))
    end)

    assert {:ok, %{"status" => "pending"}} =
             Iugu.create_invoice(
               %{
                 customer_id: "CUS",
                 due_date: "2026-09-26",
                 expires_in: ~D[2026-09-30],
                 items: [%{description: "Corte", quantity: 1, price_cents: 8_000}]
               },
               idempotency_key: "atendimento-42",
               retry_delay: 0,
               retry_log_level: false
             )

    # Without the key a timeout may have created the invoice on Iugu's side,
    # so a second attempt would mean a second invoice and a second e-mail.
    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.create_invoice(%{
               email: "cliente@exemplo.com",
               due_date: ~D[2026-09-16],
               items: [%{description: "Corte", quantity: 1, price_cents: 8_000}]
             })

    assert attempts() == 1

    # Each of these is a 422 from Iugu, or a split silently ignored at payment
    # time. No stub is standing, so the refusal is also proven to skip the
    # network.
    valid = %{
      email: "cliente@exemplo.com",
      due_date: ~D[2026-09-16],
      items: [%{description: "Corte", quantity: 1, price_cents: 8_000}]
    }

    refused = [
      {Map.delete(valid, :email), [], ~r/email ou customer_id/},
      {Map.delete(valid, :due_date), [], ~r/due_date/},
      {Map.put(valid, :items, []), [], ~r/pelo menos um item/},
      {Map.put(valid, :items, [%{description: "", quantity: 1, price_cents: 100}]), [],
       ~r/Item inválido/},
      {Map.put(valid, :items, [%{description: "Corte", quantity: 0, price_cents: 100}]), [],
       ~r/Item inválido/},
      {Map.put(valid, :items, [%{description: "Corte", quantity: 1, price_cents: 99}]), [],
       ~r/Item inválido/},
      {Map.put(valid, :payable_with, [:debit_card]), [], ~r/payable_with/},
      {Map.put(valid, :payable_with, [:bank_slip]), [], ~r/payer/},
      {Map.merge(valid, %{payable_with: [:all], payer: %{cpf_cnpj: "11343675030"}}), [],
       ~r/payer/},
      {Map.merge(valid, %{late_payment_fine: 2, late_payment_fine_cents: 200}), [],
       ~r/Somente um campo de multa/},
      {Map.put(valid, :soft_descriptor_light, "LOJA ANA CENTRO"), [], ~r/soft_descriptor_light/},
      {Map.put(valid, :external_reference, String.duplicate("x", 61)), [],
       ~r/external_reference/},
      {Map.put(valid, :splits, [Split.fixed("PRO", 8_000)]), [], ~r/abaixo do total/},
      {Map.put(valid, :splits, [Split.fixed("SUB", 100)]), [own_account_id: "SUB"],
       ~r/conta criadora/}
    ]

    for {attrs, opts, expected_message} <- refused do
      assert {:error,
              %Error{
                kind: :validation,
                status: nil,
                path: "/v1/invoices",
                messages: [message]
              }} = Iugu.create_invoice(attrs, opts)

      assert message =~ expected_message
    end

    assert Iugu.invoice_payable_with() == ["all", "credit_card", "bank_slip", "pix"]

    # A card-only invoice needs no payer, and a discount lowers the total the
    # splits are checked against: 6.999 cents pass against 8.000 - 1.000.
    expect_request(fn conn, body ->
      assert body["payable_with"] == ["credit_card"]
      refute Map.has_key?(body, "payer")
      Req.Test.json(conn, invoice_body(%{}))
    end)

    assert {:ok, _invoice} =
             Iugu.create_invoice(
               Map.merge(valid, %{
                 payable_with: [:credit_card],
                 discount_cents: 1_000,
                 splits: [Split.fixed("PRO", 6_999)]
               })
             )

    # A field the route does not know is a typo here, not a 422 there.
    assert_raise ArgumentError, ~r/due_at/, fn ->
      Iugu.create_invoice(Map.put(valid, :due_at, "2026-09-16"))
    end

    # What Iugu refuses comes back per field, and the idempotency conflict is
    # a 409 with the key still attached to the original.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{
        "errors" => %{
          "due_date" => ["não pode estar no passado"],
          "items.price_cents" => ["não pode ficar em branco"]
        }
      })
    end)

    assert {:error,
            %Error{
              kind: :validation,
              status: 422,
              fields: %{"due_date" => ["não pode estar no passado"]},
              messages: [
                "due_date: não pode estar no passado",
                "items.price_cents: não pode ficar em branco"
              ]
            }} = Iugu.create_invoice(valid)

    Req.Test.expect(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{})
    end)

    assert {:error, %Error{kind: :validation, status: 409}} =
             Iugu.create_invoice(valid, idempotency_key: "atendimento-42")
  end

  test "reads one invoice, lists with the documented filters in São Paulo time and walks every page" do
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/invoices/EBB161AAB22849BFA047D5F1DF55AEE9"
      assert_basic(conn, "iugu-test-token")

      Req.Test.json(conn, invoice_body(%{"status" => "paid", "payment_method" => "iugu_pix"}))
    end)

    assert {:ok, %{"status" => "paid", "payment_method" => "iugu_pix"} = invoice} =
             Iugu.get_invoice("EBB161AAB22849BFA047D5F1DF55AEE9")

    assert Iugu.invoice_paid?(invoice)

    Req.Test.expect(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"errors" => "Invoice Not Found"})
    end)

    assert {:error, %Error{kind: :not_found, messages: ["Invoice Not Found"]}} =
             Iugu.get_invoice("MISSING")

    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/invoices"
      assert_basic(conn, @subaccount_token)

      # DateTimes leave in the -03:00 form the docs show; limit is capped at
      # the route's 100.
      assert conn.query_params == %{
               "start" => "200",
               "limit" => "100",
               "created_at_from" => "2026-09-01T00:00:00-03:00",
               "paid_at_to" => "2026-09-03T20:59:59-03:00",
               "updated_since" => "2026-09-02T10:00:00-03:00",
               "due_date" => "2026-09-10",
               "query" => "pedido-42",
               "customer_id" => "CUS",
               "status_filter" => "pending"
             }

      Req.Test.json(conn, %{
        "items" => [invoice_body(%{"id" => "INV1"})],
        "facets" => %{
          "status" => %{"terms" => [%{"term" => "pending", "count" => 2}], "total" => 66}
        },
        "totalItems" => 66
      })
    end)

    assert {:ok,
            %{
              invoices: [%{"id" => "INV1"}],
              facets: %{"status" => %{"total" => 66}},
              page_info: %{start: 200, limit: 100, total_items: 66}
            }} =
             Iugu.list_invoices(
               start: 200,
               limit: 500,
               created_at_from: ~U[2026-09-01 03:00:00Z],
               paid_at_to: ~U[2026-09-03 23:59:59Z],
               updated_since: "2026-09-02T10:00:00-03:00",
               due_date: ~D[2026-09-10],
               query: "pedido-42",
               customer_id: "CUS",
               status_filter: "pending",
               api_token: @subaccount_token
             )

    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.list_invoices(status_filter: "unpaid")

    assert message =~ "status_filter"

    # Two full pages then a short one: the stream stops on the short page and
    # never trusts totalItems (which Iugu documents as the account total).
    Req.Test.expect(Iugu.Client, 3, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["status_filter"] == "paid"
      assert conn.query_params["limit"] == "2"

      items =
        case conn.query_params["start"] do
          "0" -> [invoice_body(%{"id" => "A"}), invoice_body(%{"id" => "B"})]
          "2" -> [invoice_body(%{"id" => "C"}), invoice_body(%{"id" => "D"})]
          "4" -> [invoice_body(%{"id" => "E"})]
        end

      Req.Test.json(conn, %{"items" => items, "totalItems" => 999})
    end)

    assert ["A", "B", "C", "D", "E"] =
             [status_filter: "paid", limit: 2, api_token: @subaccount_token]
             |> Iugu.stream_invoices()
             |> Enum.map(& &1["id"])
  end

  test "drives the lifecycle: cancels, captures, refunds in full and in part, issues a second copy, reissues an expired one, marks an external payment and resends the e-mail, each with the body the route wants" do
    expect_request_raw(fn conn, raw_body ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/invoices/INV/cancel"
      assert raw_body == ""
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      Req.Test.json(conn, invoice_body(%{"status" => "canceled"}))
    end)

    assert {:ok, %{"status" => "canceled"} = canceled} =
             Iugu.cancel_invoice("INV", api_token: @subaccount_token)

    assert Iugu.invoice_final?(canceled)
    refute Iugu.invoice_paid?(canceled)

    expect_request_raw(fn conn, raw_body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/invoices/INV/capture"
      assert raw_body == ""

      Req.Test.json(conn, invoice_body(%{"status" => "paid"}))
    end)

    assert {:ok, %{"status" => "paid"}} = Iugu.capture_invoice("INV")

    # The status precondition is Iugu's guard against repeating a write.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"errors" => "Apenas Faturas em análise podem ser capturadas"})
    end)

    assert {:error,
            %Error{
              kind: :validation,
              status: 400,
              messages: ["Apenas Faturas em análise podem ser capturadas"]
            }} = Iugu.capture_invoice("INV")

    expect_request_raw(fn conn, raw_body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/invoices/INV/refund"
      assert raw_body == ""

      Req.Test.json(conn, invoice_body(%{"status" => "refunded", "refunded_cents" => 376}))
    end)

    assert {:ok, %{"status" => "refunded"} = refunded} = Iugu.refund_invoice("INV")
    assert Iugu.invoice_final?(refunded)

    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/invoices/INV/refund"
      assert body == %{"partial_value_refund_cents" => 1_000}

      Req.Test.json(conn, invoice_body(%{"status" => "paid", "refunded_cents" => 1_000}))
    end)

    assert {:ok, %{"refunded_cents" => 1_000}} = Iugu.partially_refund_invoice("INV", 1_000)

    assert {:error, %Error{kind: :validation, status: nil, path: "/v1/invoices/INV/refund"}} =
             Iugu.partially_refund_invoice("INV", 0)

    # Second copy: the due date is mandatory, items may be edited or removed
    # by id, and the answer is a new invoice.
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/invoices/INV/duplicate"

      assert body == %{
               "due_date" => "2026-10-01",
               "items" => [
                 %{"id" => "ITEM1", "_destroy" => true},
                 %{"description" => "Corte", "quantity" => 1, "price_cents" => 9_000}
               ],
               "ignore_canceled_email" => true,
               "current_fines_option" => true
             }

      Req.Test.json(conn, invoice_body(%{"id" => "NEW", "status" => "pending"}))
    end)

    assert {:ok, %{"id" => "NEW", "status" => "pending"}} =
             Iugu.duplicate_invoice("INV", %{
               due_date: ~D[2026-10-01],
               items: [
                 %{id: "ITEM1", _destroy: true},
                 %{description: "Corte", quantity: 1, price_cents: 9_000}
               ],
               ignore_canceled_email: true,
               current_fines_option: true
             })

    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.duplicate_invoice("INV", %{ignore_due_email: true})

    assert message =~ "due_date"

    assert_raise ArgumentError, ~r/payable_with/, fn ->
      Iugu.duplicate_invoice("INV", %{due_date: ~D[2026-10-01], payable_with: "pix"})
    end

    # Reissuing an expired one: same route, everything optional, payable_with
    # as a single string.
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/invoices/EXPIRED/duplicate"
      assert body == %{"payable_with" => "pix", "due_date" => "2026-10-05"}

      Req.Test.json(conn, invoice_body(%{"id" => "REISSUED", "status" => "pending"}))
    end)

    assert {:ok, %{"id" => "REISSUED"}} =
             Iugu.reissue_expired_invoice("EXPIRED", %{payable_with: :pix, due_date: "2026-10-05"})

    expect_request(fn conn, body ->
      assert body == %{}
      Req.Test.json(conn, invoice_body(%{"id" => "REISSUED"}))
    end)

    assert {:ok, %{"id" => "REISSUED"}} = Iugu.reissue_expired_invoice("EXPIRED")

    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.reissue_expired_invoice("EXPIRED", %{payable_with: "debit_card"})

    assert message =~ "payable_with"

    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "errors" =>
          "Faturas expiradas originadas em Carnês ou Assinaturas não podem ser duplicadas."
      })
    end)

    assert {:error, %Error{kind: :validation, status: 400, messages: [reissue_message]}} =
             Iugu.reissue_expired_invoice("SUBSCRIPTION-INVOICE")

    assert reissue_message =~ "Carnês ou Assinaturas"

    expect_request(fn conn, body ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/invoices/INV/externally_pay"

      assert body == %{
               "external_payment_id" => "pix-manual-42",
               "external_payment_description" => "Pix recebido na maquininha"
             }

      Req.Test.json(
        conn,
        invoice_body(%{
          "status" => "externally_paid",
          "external_payment_id" => "pix-manual-42",
          "paid_at" => "2026-09-03T10:00:00-03:00",
          "bank_slip" => nil
        })
      )
    end)

    assert {:ok, %{"status" => "externally_paid"} = externally_paid} =
             Iugu.mark_invoice_externally_paid("INV", "pix-manual-42",
               description: "Pix recebido na maquininha"
             )

    assert Iugu.invoice_final?(externally_paid)
    refute Iugu.invoice_paid?(externally_paid)
    assert Iugu.invoice_bank_slip(externally_paid) == nil

    assert {:error, %Error{kind: :validation, status: nil, messages: [long_id]}} =
             Iugu.mark_invoice_externally_paid("INV", String.duplicate("x", 33))

    assert long_id =~ "external_payment_id"

    assert {:error, %Error{kind: :validation, status: nil, messages: [long_description]}} =
             Iugu.mark_invoice_externally_paid("INV", "ok",
               description: String.duplicate("x", 51)
             )

    assert long_description =~ "external_payment_description"

    expect_request_raw(fn conn, raw_body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/invoices/INV/send_email"
      assert raw_body == ""

      Req.Test.json(conn, invoice_body(%{"status" => "paid"}))
    end)

    assert {:ok, %{"status" => "paid"}} = Iugu.send_invoice_email("INV")
  end

  test "finds an invoice by an external identifier, on the account or across the marketplace's subaccounts" do
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/resource_search"
      assert conn.query_params == %{"query_field" => "external_id", "value" => "atendimento-42"}
      assert_basic(conn, @subaccount_token)

      Req.Test.json(conn, %{
        "referenceable_id" => "INV",
        "referenceable_type" => "Invoice",
        "resource" => invoice_body(%{"id" => "INV", "external_reference" => "atendimento-42"})
      })
    end)

    assert {:ok, %{"id" => "INV", "external_reference" => "atendimento-42"}} =
             Iugu.search_invoice_by_external_ids("external_id", "atendimento-42",
               api_token: @subaccount_token
             )

    # The master looks into its subaccounts through the marketplace twin of
    # the route, with its own token.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.request_path == "/v1/marketplace_resource_search"
      assert conn.query_params == %{"query_field" => "end_to_end", "value" => "E1234"}
      assert_basic(conn, "iugu-test-token")

      Req.Test.json(conn, %{"referenceable_type" => "Invoice", "resource" => invoice_body(%{})})
    end)

    assert {:ok, %{"id" => "EBB161AAB22849BFA047D5F1DF55AEE9"}} =
             Iugu.search_invoice_by_external_ids("end_to_end", "E1234", marketplace: true)

    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.search_invoice_by_external_ids("secure_id", "abc")

    assert message =~ "query_field"
    assert "external_id" in Iugu.invoice_search_fields()
    refute "secure_id" in Iugu.invoice_search_fields()

    # The not-found shape is undocumented; an answer without a resource is
    # reported as such instead of being read as an invoice.
    Req.Test.expect(Iugu.Client, fn conn -> Req.Test.json(conn, %{}) end)

    assert {:error, %Error{kind: :unexpected, path: "/v1/resource_search"}} =
             Iugu.search_invoice_by_external_ids("order_id", "pedido-42")
  end

  test "reads the payment data a screen needs out of the invoice: status, Pix QR Code, boleto and checkout links, splits" do
    invoice = invoice_body(%{})

    assert Iugu.invoice_statuses() == [
             "pending",
             "paid",
             "canceled",
             "in_analysis",
             "draft",
             "partially_paid",
             "refunded",
             "expired",
             "in_protest",
             "chargeback",
             "externally_paid"
           ]

    assert Iugu.invoice_status(invoice) == "pending"
    refute Iugu.invoice_paid?(invoice)
    refute Iugu.invoice_final?(invoice)

    for status <- ["paid", "externally_paid", "canceled", "expired", "refunded", "chargeback"] do
      assert Iugu.invoice_final?(%{"status" => status})
    end

    for status <- ["pending", "in_analysis", "partially_paid", "in_protest", "draft"] do
      refute Iugu.invoice_final?(%{"status" => status})
    end

    assert Iugu.invoice_secure_url(invoice) ==
             "https://checkout.iugu.com/invoices/ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03"

    assert Iugu.invoice_pdf_url(invoice) ==
             "https://checkout.iugu.com/invoices/ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03.pdf"

    assert %{
             qrcode: "https://faturas.iugu.com/qr_code/ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03",
             qrcode_text: "00020101021226890014br.gov.bcb.pix" <> _rest,
             status: "qr_code_created",
             end_to_end_id: nil
           } = Iugu.invoice_pix(invoice)

    assert %{
             digitable_line: "40192025089200000000700002008647710390000000376",
             barcode_data: "40197103900000003762025092000000000000200864",
             barcode_url:
               "https://api.iugu.com/v1/public/invoice/ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03/barcode",
             url:
               "https://boletos.iugu.com/v1/public/invoice/ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03/bank_slip",
             pdf_url:
               "https://boletos.iugu.com/v1/public/invoice/ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03/bank_slip.pdf",
             bank: 401,
             status: "pending"
           } = Iugu.invoice_bank_slip(invoice)

    assert [
             %Split{
               recipient_account_id: "E638DCED176240E4A510510C065FB52D",
               cents: 10,
               percent: 1
             }
           ] =
             Iugu.invoice_splits(invoice)

    # A card-only invoice: the pix object comes full of nulls and bank_slip
    # is null; neither reads as payment data.
    card_only =
      invoice_body(%{
        "payable_with" => "credit_card",
        "bank_slip" => nil,
        "pix" => %{"qrcode" => nil, "qrcode_text" => nil, "status" => nil},
        "split_rules" => nil,
        "secure_url" => nil
      })

    assert Iugu.invoice_pix(card_only) == nil
    assert Iugu.invoice_bank_slip(card_only) == nil
    assert Iugu.invoice_splits(card_only) == []
    assert Iugu.invoice_pdf_url(card_only) == nil
  end

  defp invoice_body(overrides) do
    Map.merge(
      %{
        "id" => "EBB161AAB22849BFA047D5F1DF55AEE9",
        "due_date" => "2025-04-02",
        "currency" => "BRL",
        "email" => "email@iugu.com",
        "items_total_cents" => 400,
        "discount_cents" => 24,
        "status" => "pending",
        "total_cents" => 376,
        "payable_with" => "all",
        "paid_at" => nil,
        "payment_method" => nil,
        "refunded_cents" => 0,
        "external_reference" => nil,
        "order_id" => nil,
        "split_id" => "3270D0BAB8074BDE98E382340338550C",
        "secure_id" => "ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03",
        "secure_url" =>
          "https://checkout.iugu.com/invoices/ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03",
        "created_at_iso" => "2025-04-02T13:14:26-03:00",
        "bank_slip" => %{
          "digitable_line" => "40192025089200000000700002008647710390000000376",
          "barcode_data" => "40197103900000003762025092000000000000200864",
          "barcode" =>
            "https://api.iugu.com/v1/public/invoice/ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03/barcode",
          "bank_slip_url" =>
            "https://boletos.iugu.com/v1/public/invoice/ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03/bank_slip",
          "bank_slip_pdf_url" =>
            "https://boletos.iugu.com/v1/public/invoice/ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03/bank_slip.pdf",
          "bank_slip_bank" => 401,
          "bank_slip_status" => "pending",
          "bank_slip_error_code" => nil,
          "recipient_cpf_cnpj" => "42135294870"
        },
        "pix" => %{
          "qrcode" =>
            "https://faturas.iugu.com/qr_code/ebb161aa-b228-49bf-a047-d5f1df55aee9-cb03",
          "qrcode_text" =>
            "00020101021226890014br.gov.bcb.pix2567qr.iugu.com/public/payload/v2/cobv/EBB161AAB22849BFA047D5F1DF55AEE952040000530398654043.765802BR5924NOME DA CONTA6009SAO PAULO62070503***630405E6",
          "status" => "qr_code_created",
          "payer_cpf_cnpj" => nil,
          "end_to_end_id" => nil
        },
        "items" => [
          %{
            "id" => "03B95185",
            "description" => "Nome do Item",
            "price_cents" => 300,
            "quantity" => 1
          }
        ],
        "split_rules" => [
          %{
            "id" => "AB1B22F356464105A3C17BA18A640BA9",
            "split_id" => "3270D0BAB8074BDE98E382340338550C",
            "recipient_account_id" => "E638DCED176240E4A510510C065FB52D",
            "cents" => 10,
            "percent" => 1,
            "credit_card_cents" => nil,
            "pix_percent" => nil,
            "permit_aggregated" => true,
            "credit_card_1x_cents" => nil,
            "credit_card_18x_percent" => nil
          }
        ]
      },
      overrides
    )
  end
end
