defmodule IuguTest do
  @moduledoc """
  A fachada do SDK: é por ela que o resto do projeto entra, e é ela que o
  moduledoc de `Iugu` ensina a usar. Os submódulos têm os testes das
  regras de cada endpoint; aqui o que está sob teste é o fluxo do marketplace
  inteiro, visto de fora, com o token certo em cada passo.
  """
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Split
  alias Iugu.Webhook.Event

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @master_id "MASTER"
  @subaccount_id "49196DF60BC64B6EB42DEC9C5D81C2CC"
  @live_token "SUBACCOUNT-LIVE-TOKEN"
  @user_token "SUBACCOUNT-USER-TOKEN"

  test "drives a subaccount from creation to withdraw through the facade, with the token each step needs" do
    {private_key_pem, public_key} = generate_key_pair()

    # Creation and KYC: the master creates and signs, the subaccount verifies
    # itself with its user_token.
    Req.Test.stub(Iugu.Client, fn conn ->
      {conn, body, raw_body} = read_body(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/v1/signature/validate"} ->
          assert_basic(conn, "iugu-test-token")
          assert_signed(conn, raw_body, public_key, "iugu-test-token")
          assert body == %{"RAW_BODY" => "iugu"}

          Req.Test.json(conn, %{
            "message" => "Signature check successful",
            "request_body" => raw_body,
            "status" => "ok"
          })

        {"POST", "/v1/marketplace/create_account"} ->
          assert_basic(conn, "iugu-test-token")
          assert conn.query_params == %{"api_token" => "iugu-test-token"}
          assert_signed(conn, raw_body, public_key, "iugu-test-token")

          assert body == %{
                   "name" => "Loja Ana",
                   "splits" => [%{"recipient_account_id" => @master_id, "percent" => 30}]
                 }

          Req.Test.json(conn, %{
            "account_id" => @subaccount_id,
            "name" => "Loja Ana",
            "live_api_token" => @live_token,
            "test_api_token" => "SUBACCOUNT-TEST-TOKEN",
            "user_token" => @user_token
          })

        {"POST", "/v1/accounts/" <> _rest = path} ->
          assert path == "/v1/accounts/#{@subaccount_id}/request_verification"
          assert_basic(conn, @user_token)
          assert_unsigned(conn)

          assert body["data"]["person_type"] == "Pessoa Física"
          assert body["data"]["cpf"] == "12345678909"
          # Cents in, the "100.00" string the route wants out.
          assert body["data"]["estimated_revenue"] == "5000.00"
          refute Map.has_key?(body["data"], "estimated_revenue_cents")
          assert Map.keys(body["files"]) == ["identification", "selfie"]

          Req.Test.json(conn, %{
            "id" => "VERIFICATION-ID",
            "account_id" => @subaccount_id,
            "data" => body["data"]
          })
      end
    end)

    # The dry run comes first: the key pair is proven against Iugu before it
    # signs anything that creates an account or moves money.
    assert {:ok, %{message: "Signature check successful", status: "ok"}} =
             Iugu.validate_signature("iugu", signature_private_key: private_key_pem)

    assert {:ok, subaccount} =
             Iugu.create_account("Loja Ana",
               splits: [%{recipient_account_id: @master_id, percent: 30}],
               signature_private_key: private_key_pem
             )

    assert %{
             account_id: @subaccount_id,
             live_api_token: @live_token,
             test_api_token: "SUBACCOUNT-TEST-TOKEN",
             user_token: @user_token
           } = subaccount

    assert {:ok, %{"id" => "VERIFICATION-ID"}} =
             Iugu.request_account_verification(
               subaccount.account_id,
               verification_data(),
               %{
                 identification: "data:image/jpeg;name=rg.jpg;base64,QUJD",
                 selfie: "data:image/jpeg;name=selfie.jpg;base64,REVG"
               },
               api_token: subaccount.user_token
             )

    # Approval arrives by webhook; the delivery is a form, not JSON, and it
    # carries the authorization we configured.
    assert {:ok, %Event{event: "referrals.verification"} = approval} =
             Event.decode_form(
               "event=referrals.verification&data[id]=VERIFICATION-ID" <>
                 "&data[account_id]=#{@subaccount_id}&data[status]=accepted"
             )

    assert Event.verified?(approval)
    assert Event.authorized?("iugu-test-webhook-authorization")

    # Charging with split: the master creates the invoice with its default
    # token, the subaccount reads its own balance with its live token.
    Req.Test.stub(Iugu.Client, fn conn ->
      {conn, body, _raw_body} = read_body(conn)

      case {conn.method, conn.request_path} do
        {"GET", "/v1/accounts/" <> account_id} ->
          assert account_id == @subaccount_id
          assert_basic(conn, @live_token)
          assert_unsigned(conn)

          Req.Test.json(conn, %{
            "id" => @subaccount_id,
            "name" => "Loja Ana",
            "is_verified?" => true,
            "can_receive?" => true,
            "last_verification_request_status" => "accepted",
            "balance" => "R$ 70,00",
            "balance_available_for_withdraw" => "R$ 70,00",
            "splits" => []
          })

        {"POST", "/v1/invoices"} ->
          assert_basic(conn, "iugu-test-token")
          assert_unsigned(conn)
          assert body["email"] == "cliente@example.com"
          assert body["due_date"] == "2026-09-10"
          assert body["payable_with"] == ["pix"]

          assert body["items"] == [
                   %{"description" => "Corte + escova", "quantity" => 1, "price_cents" => 10_000}
                 ]

          assert body["splits"] == [
                   %{"recipient_account_id" => @subaccount_id, "percent" => 70}
                 ]

          Req.Test.json(conn, %{
            "id" => "INVOICE-ID",
            "status" => "pending",
            "secure_url" => "https://faturas.iugu.com/INVOICE-ID",
            "pix" => %{
              "qrcode" => "https://faturas.iugu.com/INVOICE-ID.png",
              "qrcode_text" => "00020101021226...",
              "status" => "qr_code_created"
            }
          })

        {"GET", "/v1/invoices/INVOICE-ID"} ->
          assert_basic(conn, "iugu-test-token")

          Req.Test.json(conn, %{
            "id" => "INVOICE-ID",
            "status" => "paid",
            "paid_cents" => 10_000,
            "split_rules" => [
              %{"recipient_account_id" => @subaccount_id, "percent" => 70, "cents" => nil}
            ]
          })
      end
    end)

    assert {:ok, %{verified?: true, can_receive?: true}} =
             Iugu.get_account(subaccount.account_id, api_token: subaccount.live_api_token)

    assert {:ok, invoice} =
             Iugu.create_invoice(
               %{
                 email: "cliente@example.com",
                 due_date: ~D[2026-09-10],
                 items: [%{description: "Corte + escova", quantity: 1, price_cents: 10_000}],
                 payable_with: [:pix],
                 payer: %{cpf_cnpj: "12345678909", name: "Maria Silva"},
                 splits: [Split.percent(subaccount.account_id, 70)]
               },
               own_account_id: @master_id
             )

    assert Iugu.invoice_status(invoice) == "pending"
    refute Iugu.invoice_paid?(invoice)

    assert %{qrcode_text: "00020101021226...", status: "qr_code_created"} =
             Iugu.invoice_pix(invoice)

    assert {:ok, paid_invoice} = Iugu.get_invoice("INVOICE-ID")
    assert Iugu.invoice_paid?(paid_invoice)
    assert Iugu.invoice_final?(paid_invoice)

    assert [%Split{recipient_account_id: @subaccount_id, percent: 70, cents: nil}] =
             Iugu.invoice_splits(paid_invoice)

    assert {:ok, %{balance_available_for_withdraw_cents: 7_000}} =
             Iugu.get_account(subaccount.account_id, api_token: subaccount.live_api_token)

    # Cash out: the subaccount withdraws its own balance (signed with the
    # master's key, authenticated with its live token, amount in reais) and
    # transfers our fee back to the master.
    Req.Test.stub(Iugu.Client, fn conn ->
      {conn, body, raw_body} = read_body(conn)

      case {conn.method, conn.request_path} do
        {"POST", "/v1/accounts/" <> _rest = path} ->
          assert path == "/v1/accounts/#{@subaccount_id}/request_withdraw"
          assert_basic(conn, @live_token)
          assert conn.query_params == %{"api_token" => @live_token}
          assert_signed(conn, raw_body, public_key, @live_token)
          assert body == %{"amount" => 70.0}

          Req.Test.json(conn, %{
            "id" => "WITHDRAW-ID",
            "status" => "pending",
            "receipt_url" => "https://comprovantes.iugu.com/WITHDRAW-ID"
          })

        {"POST", "/v1/transfers"} ->
          assert_basic(conn, @live_token)
          assert_signed(conn, raw_body, public_key, @live_token)
          assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["saque-WITHDRAW-ID"]
          assert body == %{"receiver_id" => @master_id, "amount_cents" => 250}

          Req.Test.json(conn, %{
            "id" => "TRANSFER-ID",
            "amount_cents" => 250,
            "amount_localized" => "R$ 2,50",
            "sender" => %{"id" => @subaccount_id, "name" => "Loja Ana"},
            "receiver" => %{"id" => @master_id, "name" => "Matriz"}
          })

        {"GET", "/v1/withdraw_requests/WITHDRAW-ID"} ->
          assert_basic(conn, @live_token)

          Req.Test.json(conn, %{
            "id" => "WITHDRAW-ID",
            "status" => "accepted",
            "amount" => "R$ 70,00",
            "receipt_url" => "https://comprovantes.iugu.com/WITHDRAW-ID"
          })
      end
    end)

    assert {:ok, %{"id" => "WITHDRAW-ID", "status" => "pending"}} =
             Iugu.request_withdraw(subaccount.account_id, 7_000,
               api_token: subaccount.live_api_token,
               signature_private_key: private_key_pem
             )

    assert {:ok, %{id: "TRANSFER-ID", amount_cents: 250, receiver: %{id: @master_id}}} =
             Iugu.create_transfer(@master_id, 250,
               api_token: subaccount.live_api_token,
               signature_private_key: private_key_pem,
               idempotency_key: "saque-WITHDRAW-ID"
             )

    assert {:ok, %{status: "accepted", amount_cents: 7_000}} =
             Iugu.get_withdraw_request("WITHDRAW-ID", api_token: subaccount.live_api_token)
  end

  test "registers the webhooks of a URL through the facade without duplicating the ones already there" do
    url = "https://app.example.com/v1/webhooks/iugu"

    Req.Test.stub(Iugu.Client, fn conn ->
      {conn, body, _raw_body} = read_body(conn)

      case {conn.method, conn.request_path} do
        {"GET", "/v1/web_hooks/supported_events"} ->
          Req.Test.json(conn, ["all", "invoice.status_changed", "referrals.verification"])

        {"GET", "/v1/web_hooks"} ->
          Req.Test.json(conn, [
            %{
              "id" => "HOOK-1",
              "url" => url,
              "event" => "invoice.status_changed",
              "authorization" => "iugu-test-webhook-authorization",
              "active" => true
            }
          ])

        {"POST", "/v1/web_hooks"} ->
          assert body == %{
                   "url" => url,
                   "event" => "referrals.verification",
                   "authorization" => "iugu-test-webhook-authorization"
                 }

          Req.Test.json(conn, Map.put(body, "id", "HOOK-2"))
      end
    end)

    assert {:ok, report} = Iugu.sync_webhooks(url, request_interval_ms: 0)

    assert [%{event: "referrals.verification", id: "HOOK-2"}] = report.created
    assert [%{event: "invoice.status_changed", id: "HOOK-1"}] = report.unchanged
    assert report.failed == []

    assert {:ok, [%{id: "HOOK-1", event: "invoice.status_changed"}]} =
             Iugu.list_webhooks(url: url)

    assert "invoice.status_changed" in Iugu.invoice_webhook_events()
    assert "referrals.verification" in Iugu.kyc_webhook_events()
  end

  defp verification_data do
    %{
      price_range: "Até R$ 100,00",
      physical_products: false,
      business_type: "Loja de roupas",
      person_type: "Pessoa Física",
      automatic_transfer: true,
      cpf: "12345678909",
      name: "Ana Souza",
      street: "Rua das Flores",
      number: "100",
      district: "Centro",
      cep: "40000-000",
      city: "Salvador",
      state: "BA",
      telephone: "71999999999",
      estimated_revenue_cents: 500_000,
      bank: "Itaú",
      bank_ag: "0001",
      account_type: "Corrente",
      bank_cc: "12345-6",
      politically_exposed_person: false,
      website: "https://lojaana.com.br"
    }
  end

  defp read_body(conn) do
    conn = Plug.Conn.fetch_query_params(conn)
    {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
    body = if raw_body == "", do: %{}, else: Jason.decode!(raw_body)

    {conn, body, raw_body}
  end
end
