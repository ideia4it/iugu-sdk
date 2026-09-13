defmodule Iugu.ChargeTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  doctest Iugu.Charge

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"

  test "charges a card with a one-shot token, reads the transaction, turns a 200 decline into a declined error with its LR and never retries" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/charge"
      assert_basic(conn, @subaccount_token)
      assert Plug.Conn.get_req_header(conn, "signature") == []

      # Card is implied by the token: there is no method: "credit_card".
      assert body == %{
               "token" => "d2a133e0-280c-4401-8624-94cd84254ac5",
               "email" => "cliente@exemplo.com",
               "items" => [
                 %{"description" => "Corte", "quantity" => 1, "price_cents" => 8_000},
                 %{"description" => "Cupom", "quantity" => 1, "price_cents" => -1_000}
               ],
               "payer" => %{
                 "cpf_cnpj" => "113.436.750-30",
                 "name" => "Nome do Pagador",
                 "address" => %{"zip_code" => "01310-100", "number" => "1000"}
               },
               "months" => 2,
               "order_id" => "atendimento-42",
               "soft_descriptor_light" => "LOJA ANA",
               "keep_dunning" => true
             }

      Req.Test.json(conn, card_success_body(%{}))
    end)

    assert {:ok, charge} =
             Iugu.create_charge(
               %{
                 token: "d2a133e0-280c-4401-8624-94cd84254ac5",
                 email: "cliente@exemplo.com",
                 items: [
                   %{description: "Corte", quantity: 1, price_cents: 8_000},
                   %{"description" => "Cupom", "quantity" => 1, "price_cents" => -1_000}
                 ],
                 payer: %{
                   cpf_cnpj: "113.436.750-30",
                   name: "Nome do Pagador",
                   address: %{zip_code: "01310-100", number: "1000"}
                 },
                 months: 2,
                 order_id: "atendimento-42",
                 soft_descriptor_light: "LOJA ANA",
                 keep_dunning: true
               },
               api_token: @subaccount_token
             )

    assert Iugu.charge_authorized?(charge)
    assert Iugu.charge_invoice_id(charge) == "1A4270450AFC4BFDA582BED6D7141DED"

    assert Iugu.charge_url(charge) ==
             "https://checkout.iugu.com/invoices/1a427045-0afc-4bfd-a582-bed6d7141ded-a5d1"

    assert Iugu.charge_pdf_url(charge) ==
             "https://checkout.iugu.com/invoices/1a427045-0afc-4bfd-a582-bed6d7141ded-a5d1.pdf"

    assert Iugu.charge_lr(charge) == "00"
    assert Iugu.lr_category(Iugu.charge_lr(charge)) == :authorized
    assert Iugu.charge_identification(charge) == nil
    assert Iugu.charge_bank_slip(charge) == nil

    assert %{
             status: "captured",
             lr: "00",
             message: "Autorizado",
             info_message: "Transação capturada",
             brand: nil,
             bin: nil,
             last4: nil,
             issuer: nil,
             reversible?: nil,
             transaction_token: "000000000000000000000000000000000000001"
           } = Iugu.charge_card(charge)

    # A decline is HTTP 200 with success false. The invoice_id is still there
    # because keep_dunning left the invoice pending.
    Req.Test.expect(Iugu.Client, fn conn ->
      Req.Test.json(
        conn,
        card_success_body(%{
          "success" => false,
          "status" => "unauthorized",
          "message" => "Não Autorizado",
          "info_message" => "Transação não autorizada",
          "LR" => "51",
          "brand" => "Visa",
          "bin" => 401_288,
          "last4" => "1881"
        })
      )
    end)

    assert {:error,
            %Error{
              kind: :declined,
              status: 200,
              lr: "51",
              messages: ["Não Autorizado"],
              path: "/v1/charge",
              body:
                %{"success" => false, "invoice_id" => "1A4270450AFC4BFDA582BED6D7141DED"} = body
            } = declined} = Iugu.create_charge(%{token: "tok", email: "c@e.com", items: items()})

    refute Error.retriable?(declined)
    assert Iugu.lr_category(declined) == :insufficient_funds

    assert %{brand: "Visa", bin: "401288", last4: "1881", status: "unauthorized"} =
             Iugu.charge_card(body)

    # A decline with only an errors map still says something in the log.
    Req.Test.expect(Iugu.Client, fn conn ->
      Req.Test.json(conn, %{
        "success" => false,
        "errors" => %{"base" => ["Valor da fatura excede o limite de cobrança"]},
        "message" => ""
      })
    end)

    assert {:error, %Error{kind: :declined, lr: nil, messages: [errors_message]}} =
             Iugu.create_charge(%{token: "tok", email: "c@e.com", items: items()})

    assert errors_message =~ "Valor da fatura excede"

    # A 200 that is not a charge answer is not read as one either way.
    Req.Test.expect(Iugu.Client, fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

    assert {:error, %Error{kind: :unexpected, path: "/v1/charge"}} =
             Iugu.create_charge(%{token: "tok", email: "c@e.com", items: items()})

    # The token is single use and there is no idempotency key, so a timeout
    # is reported once even when a retry is asked for: the second attempt
    # could charge the card twice.
    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.create_charge(%{token: "tok", email: "c@e.com", items: items()},
               retry: :transient
             )

    assert attempts() == 1

    # With an Idempotency-Key the header goes out and the timeout is retried:
    # Iugu answers the repeat with 409 instead of a second charge.
    test_pid = self()

    Req.Test.expect(Iugu.Client, 2, fn conn ->
      send(test_pid, :iugu_attempt)
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["atendimento-42"]

      case attempts_so_far() do
        1 -> Req.Test.transport_error(conn, :timeout)
        _later -> Req.Test.json(conn, card_success_body(%{}))
      end
    end)

    assert {:ok, %{"success" => true}} =
             Iugu.create_charge(%{token: "tok", email: "c@e.com", items: items()},
               idempotency_key: "atendimento-42",
               retry_delay: 0,
               retry_log_level: false
             )

    assert attempts() == 2

    # Iugu's own refusals arrive as usual.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"errors" => "token não é válido"})
    end)

    assert {:error, %Error{kind: :validation, status: 400, messages: ["token não é válido"]}} =
             Iugu.create_charge(%{token: "used", email: "c@e.com", items: items()})
  end

  test "issues a registered bank slip and reads the digitable line and the slip links" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/charge"

      assert body == %{
               "method" => "bank_slip",
               "restrict_payment_method" => true,
               "bank_slip_extra_days" => 5,
               "payer" => %{
                 "cpf_cnpj" => "113.436.750-30",
                 "name" => "Nome do Cliente",
                 "email" => "email@iugu.com",
                 "address" => %{"zip_code" => "01310-100", "number" => "1000"}
               },
               "items" => [%{"description" => "Corte", "quantity" => 1, "price_cents" => 1_000}]
             }

      Req.Test.json(conn, %{
        "success" => true,
        "url" =>
          "https://checkout.iugu.com/invoices/d819a14d-cb10-4c1d-80c7-e14d040a18cc-5213?bs=true",
        "pdf" =>
          "https://checkout.iugu.com/invoices/d819a14d-cb10-4c1d-80c7-e14d040a18cc-5213.pdf",
        "bank_slip_url" =>
          "https://boletos.iugu.com/v1/public/invoice/d819a14d-cb10-4c1d-80c7-e14d040a18cc-5213/bank_slip",
        "bank_slip_pdf_url" =>
          "https://boletos.iugu.com/v1/public/invoice/d819a14d-cb10-4c1d-80c7-e14d040a18cc-5213/bank_slip.pdf",
        "identification" => "40192025089200000000700002597151910420000005000",
        "invoice_id" => "D819A14DCB104C1D80C7E14D040A18CC"
      })
    end)

    # The docs' own example carries the e-mail only inside payer.
    assert {:ok, slip} =
             Iugu.create_charge(%{
               method: :bank_slip,
               restrict_payment_method: true,
               bank_slip_extra_days: 5,
               payer: %{
                 cpf_cnpj: "113.436.750-30",
                 name: "Nome do Cliente",
                 email: "email@iugu.com",
                 address: %{zip_code: "01310-100", number: "1000"}
               },
               items: [%{description: "Corte", quantity: 1, price_cents: 1_000}]
             })

    assert Iugu.charge_authorized?(slip)
    assert Iugu.charge_invoice_id(slip) == "D819A14DCB104C1D80C7E14D040A18CC"
    assert Iugu.charge_identification(slip) == "40192025089200000000700002597151910420000005000"

    assert %{
             digitable_line: "40192025089200000000700002597151910420000005000",
             url:
               "https://boletos.iugu.com/v1/public/invoice/d819a14d-cb10-4c1d-80c7-e14d040a18cc-5213/bank_slip",
             pdf_url:
               "https://boletos.iugu.com/v1/public/invoice/d819a14d-cb10-4c1d-80c7-e14d040a18cc-5213/bank_slip.pdf"
           } = Iugu.charge_bank_slip(slip)

    assert Iugu.charge_card(slip) == nil
    assert Iugu.charge_lr(slip) == nil

    # Older examples omit the slip URLs; the digitable line still reads.
    assert %{digitable_line: "4019", url: nil, pdf_url: nil} =
             Iugu.charge_bank_slip(%{"success" => true, "identification" => "4019"})

    # The registered slip needs somebody to be registered to.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{
        "errors" => %{
          "payer.address.zip_code" => ["não pode ficar em branco", "não é válido"],
          "payer.address.number" => ["não pode ficar em branco"]
        }
      })
    end)

    assert {:error,
            %Error{
              kind: :validation,
              status: 422,
              fields: %{"payer.address.number" => ["não pode ficar em branco"]}
            }} =
             Iugu.create_charge(%{
               method: "bank_slip",
               payer: %{cpf_cnpj: "113.436.750-30", name: "Nome", email: "e@e.com"},
               items: items()
             })
  end

  test "charges a saved card by customer, pays an existing invoice, and refuses before the call every combination the route rejects" do
    # One click: the saved card and the customer, no e-mail needed.
    expect_request(fn conn, body ->
      assert body == %{
               "customer_payment_method_id" => "A3AE4AB7486741E282AA77053C231779",
               "customer_id" => "138C7CBCBC9547F9873B6084BA4ACC87",
               "items" => [%{"description" => "Corte", "quantity" => 1, "price_cents" => 5_000}]
             }

      Req.Test.json(conn, card_success_body(%{}))
    end)

    assert {:ok, _charge} =
             Iugu.create_charge(%{
               customer_payment_method_id: "A3AE4AB7486741E282AA77053C231779",
               customer_id: "138C7CBCBC9547F9873B6084BA4ACC87",
               items: [%{description: "Corte", quantity: 1, price_cents: 5_000}]
             })

    # The customer's default card: customer_id alone.
    expect_request(fn conn, body ->
      assert body == %{"customer_id" => "CUS", "items" => items_body(), "discount_cents" => 500}
      Req.Test.json(conn, card_success_body(%{}))
    end)

    assert {:ok, _charge} =
             Iugu.create_charge(%{customer_id: "CUS", items: items(), discount_cents: 500})

    # Two-step flow or per-invoice splits: pay the invoice that already exists.
    expect_request(fn conn, body ->
      assert body == %{
               "customer_payment_method_id" => "FDEB80CC57EA4BA1ADE6C7119CB702CD",
               "invoice_id" => "892CFB1F859940669B62BA0A433B5F10"
             }

      Req.Test.json(conn, card_success_body(%{"status" => "authorized"}))
    end)

    assert {:ok, %{"status" => "authorized"}} =
             Iugu.create_charge(%{
               customer_payment_method_id: "FDEB80CC57EA4BA1ADE6C7119CB702CD",
               invoice_id: "892CFB1F859940669B62BA0A433B5F10"
             })

    # Each of these is a documented 400 or 422; no stub is standing, so the
    # refusal is also proven to skip the network.
    valid = %{token: "tok", email: "c@e.com", items: items()}

    refused = [
      {Map.delete(valid, :token), ~r/forma de pagar/},
      {Map.put(valid, :customer_payment_method_id, "PM"), ~r/não os dois/},
      {Map.put(valid, :method, "credit_card"), ~r/method inválido/},
      {Map.put(valid, :method, :bank_slip), ~r/bank_slip não aceita token/},
      {Map.put(valid, :invoice_id, "INV"), ~r/email não é preenchido/},
      {%{token: "tok", invoice_id: "INV", items: items()}, ~r/items são herdados/},
      {Map.put(valid, :items, []), ~r/pelo menos um item/},
      {Map.put(valid, :items, List.duplicate(hd(items()), 31)), ~r/máximo de items/},
      {Map.put(valid, :items, [%{description: "Corte", quantity: 0, price_cents: 100}]),
       ~r/Item inválido/},
      {Map.put(valid, :items, [%{description: "Corte", quantity: 1, price_cents: 99}]),
       ~r/pelo menos R\$ 1,00/},
      {Map.put(valid, :discount_cents, 4_950), ~r/pelo menos R\$ 1,00/},
      {Map.delete(valid, :email), ~r/email, customer_id ou payer.email/},
      {%{method: "bank_slip", payer: %{email: "c@e.com"}, items: items()}, ~r/cpf_cnpj e name/},
      {Map.put(valid, :months, 1), ~r/months inválido/},
      {Map.put(valid, :months, 13), ~r/months inválido/},
      {Map.put(valid, :months, 12), ~r/Parcela mínima/},
      {%{
         method: :bank_slip,
         months: 2,
         payer: %{cpf_cnpj: "1", name: "N", email: "e@e"},
         items: items()
       }, ~r/não se aplica a boleto/},
      {Map.put(valid, :soft_descriptor_light, "LOJA ANA CENTRO"), ~r/soft_descriptor_light/}
    ]

    for {attrs, expected_message} <- refused do
      assert {:error,
              %Error{kind: :validation, status: nil, path: "/v1/charge", messages: [message]}} =
               Iugu.create_charge(attrs)

      assert message =~ expected_message, "#{inspect(attrs)} -> #{message}"
    end

    # A field the route does not know is a typo here, not a 422 there; splits
    # in particular belong to the invoice.
    assert_raise ArgumentError, ~r/splits/, fn ->
      Iugu.create_charge(Map.put(valid, :splits, []))
    end

    # 10 installments of R$ 5,00 on R$ 50,00 pass; a bank slip via an
    # invoice inherits its payer.
    expect_request(fn conn, body ->
      assert body["months"] == 10
      Req.Test.json(conn, card_success_body(%{}))
    end)

    assert {:ok, _charge} = Iugu.create_charge(Map.put(valid, :months, 10))

    expect_request(fn conn, body ->
      assert body == %{"method" => "bank_slip", "invoice_id" => "INV"}
      Req.Test.json(conn, %{"success" => true, "identification" => "4019", "invoice_id" => "INV"})
    end)

    assert {:ok, %{"invoice_id" => "INV"}} =
             Iugu.create_charge(%{method: :bank_slip, invoice_id: "INV"})
  end

  test "splits an invoice between two cards with the api_token in the body and reports the leg the issuer refused" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/charge_two_credit_cards"
      assert_basic(conn, @subaccount_token)

      assert body == %{
               "api_token" => @subaccount_token,
               "invoice_id" => "BD9B9AE34DD44B08A75AB245CEA9B78D",
               "iugu_credit_card_payment" => [
                 %{"token" => "tok-1", "amount" => 500},
                 %{"token" => "tok-2", "amount" => 500}
               ]
             }

      Req.Test.json(conn, %{
        "invoice" => %{"status" => "paid"},
        "credit_card_transactions" => [
          two_cards_leg(%{"last4" => "5076"}),
          two_cards_leg(%{"last4" => "1111"})
        ]
      })
    end)

    assert {:ok,
            %{
              invoice_status: "paid",
              transactions: [%{"last4" => "5076"}, %{"last4" => "1111"}],
              body: %{"invoice" => %{"status" => "paid"}}
            }} =
             Iugu.create_charge_with_two_cards(
               "BD9B9AE34DD44B08A75AB245CEA9B78D",
               [
                 %{token: "tok-1", amount_cents: 500},
                 %{"token" => "tok-2", "amount_cents" => 500}
               ],
               api_token: @subaccount_token
             )

    # Without api_token: the SDK default goes in the body too.
    expect_request(fn conn, body ->
      assert body["api_token"] == "iugu-test-token"

      Req.Test.json(conn, %{
        "invoice" => %{"status" => "pending"},
        "credit_card_transactions" => [
          two_cards_leg(%{}),
          two_cards_leg(%{"success" => false, "LR" => "51", "message" => "Saldo insuficiente"})
        ]
      })
    end)

    assert {:error, %Error{kind: :declined, lr: "51", messages: ["Saldo insuficiente"]}} =
             Iugu.create_charge_with_two_cards("INV", [
               %{token: "tok-1", amount_cents: 500},
               %{token: "tok-2", amount_cents: 500}
             ])

    refused = [
      {[%{token: "tok-1", amount_cents: 1_000}], ~r/exatamente dois/},
      {[%{token: "tok-1", amount_cents: 500}, %{token: "", amount_cents: 500}],
       ~r/token \(string\) e amount_cents/},
      {[%{token: "tok-1", amount_cents: 500}, %{token: "tok-2", amount_cents: 0}],
       ~r/token \(string\) e amount_cents/}
    ]

    for {payments, expected_message} <- refused do
      assert {:error,
              %Error{
                kind: :validation,
                status: nil,
                path: "/v1/charge_two_credit_cards",
                messages: [message]
              }} = Iugu.create_charge_with_two_cards("INV", payments)

      assert message =~ expected_message
    end

    Req.Test.expect(Iugu.Client, fn conn -> Req.Test.json(conn, %{}) end)

    assert {:error, %Error{kind: :unexpected, path: "/v1/charge_two_credit_cards"}} =
             Iugu.create_charge_with_two_cards("INV", [
               %{token: "tok-1", amount_cents: 500},
               %{token: "tok-2", amount_cents: 500}
             ])
  end

  test "reconciles a lost answer through the card transactions, filtered in São Paulo time and walked page by page" do
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/credit_card_transactions"
      assert_basic(conn, @subaccount_token)

      assert conn.query_params == %{
               "start" => "0",
               "limit" => "100",
               "created_at_from" => "2026-09-01T00:00:00-03:00",
               "created_at_to" => "2026-09-03T23:59:59-03:00",
               "status" => "captured"
             }

      Req.Test.json(conn, %{
        "items" => [
          %{
            "id" => "TX1",
            "invoice_id" => "1A4270450AFC4BFDA582BED6D7141DED",
            "status" => "captured",
            "lr" => "00",
            "last4" => "4444",
            "test_mode" => true
          }
        ],
        "totalItems" => 1
      })
    end)

    assert {:ok,
            %{
              transactions: [%{"id" => "TX1", "status" => "captured"}],
              page_info: %{start: 0, limit: 100, total_items: 1}
            }} =
             Iugu.list_credit_card_transactions(
               start: 0,
               limit: 200,
               created_at_from: ~U[2026-09-01 03:00:00Z],
               created_at_to: "2026-09-03T23:59:59-03:00",
               status: "captured",
               api_token: @subaccount_token
             )

    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.list_credit_card_transactions(status: "paid")

    assert message =~ "status"
    assert "unauthorized" in Iugu.credit_card_transaction_statuses()

    # A bad token here is a 400 "Unauthorized", not a 401.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"errors" => "Unauthorized"})
    end)

    assert {:error, %Error{kind: :validation, status: 400, messages: ["Unauthorized"]}} =
             Iugu.list_credit_card_transactions()

    Req.Test.expect(Iugu.Client, 2, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["limit"] == "2"

      items =
        case conn.query_params["start"] do
          "0" -> [%{"id" => "A"}, %{"id" => "B"}]
          "2" -> [%{"id" => "C"}]
        end

      Req.Test.json(conn, %{"items" => items, "totalItems" => 999})
    end)

    assert ["A", "B", "C"] =
             [limit: 2] |> Iugu.stream_credit_card_transactions() |> Enum.map(& &1["id"])
  end

  test "groups every LR the way the screen needs to react, whatever the zero padding" do
    assert Iugu.lr_category("0") == :authorized
    assert Iugu.lr_category("11") == :authorized
    assert Iugu.lr_category("91") == :retry_later
    assert Iugu.lr_category("99a") == :retry_later
    assert Iugu.lr_category("BP900") == :retry_later
    assert Iugu.lr_category("54") == :fix_card_data
    assert Iugu.lr_category("01") == :fix_card_data
    assert Iugu.lr_category("EB") == :installments
    assert Iugu.lr_category("07") == :do_not_retry
    assert Iugu.lr_category("AF02") == :do_not_retry
    assert Iugu.lr_category("DM") == :insufficient_funds
    assert Iugu.lr_category("XYZ") == :unknown
    assert Iugu.lr_category(nil) == :unknown
    assert Iugu.lr_category(%Error{kind: :declined, lr: nil}) == :unknown
  end

  defp items, do: [%{description: "Corte", quantity: 1, price_cents: 5_000}]
  defp items_body, do: [%{"description" => "Corte", "quantity" => 1, "price_cents" => 5_000}]

  defp card_success_body(overrides) do
    Map.merge(
      %{
        "message" => "Autorizado",
        "errors" => %{},
        "status" => "captured",
        "info_message" => "Transação capturada",
        "reversible" => nil,
        "token" => "000000000000000000000000000000000000001",
        "brand" => nil,
        "bin" => nil,
        "last4" => nil,
        "issuer" => nil,
        "success" => true,
        "url" => "https://checkout.iugu.com/invoices/1a427045-0afc-4bfd-a582-bed6d7141ded-a5d1",
        "pdf" =>
          "https://checkout.iugu.com/invoices/1a427045-0afc-4bfd-a582-bed6d7141ded-a5d1.pdf",
        "identification" => nil,
        "invoice_id" => "1A4270450AFC4BFDA582BED6D7141DED",
        "LR" => "00"
      },
      overrides
    )
  end

  defp two_cards_leg(overrides) do
    Map.merge(
      %{
        "reversible" => true,
        "last4" => "5076",
        "bin" => 516_292,
        "brand" => "Master",
        "token" => "token",
        "message" => "Transacao capturada com sucesso",
        "success" => true,
        "issuer" => "BANCO X",
        "invoice_id" => "BD9B9AE34DD44B08A75AB245CEA9B78D",
        "LR" => "00"
      },
      overrides
    )
  end
end
