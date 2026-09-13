defmodule Iugu.AccountTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"
  @user_token "SUBACCOUNT-USER-TOKEN"

  test "reads a subaccount with its own live token and turns the localized balances into cents, leaving an unreadable one nil" do
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/accounts/ACC"
      # The master token gets nothing here: the subaccount reads itself.
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      Req.Test.json(
        conn,
        account_body(%{
          "balance" => "R$ 1.234,56",
          "balance_available_for_withdraw" => "R$ 1.000,00",
          "payable_balance" => "R$ -2,47",
          "subaccounts_negative_balance_total" => "R$100,00"
        })
      )
    end)

    assert {:ok, account} = Iugu.get_account("ACC", api_token: @subaccount_token)

    assert %{
             id: "ACC",
             name: "Loja Ana",
             verified?: true,
             can_receive?: true,
             has_bank_address?: true,
             marketplace?: false,
             last_verification_request_status: "accepted",
             last_verification_request_feedback: nil,
             auto_withdraw: false,
             disabled_withdraw: false,
             auto_advance: true,
             auto_advance_type: "daily",
             balance_cents: 123_456,
             balance_available_for_withdraw_cents: 100_000,
             balance_in_protest_cents: 0,
             protected_balance_cents: 0,
             payable_balance_cents: -247,
             receivable_balance_cents: 2_000,
             commission_balance_cents: 0,
             customer_minimum_balance_cents: 3_000,
             bank_accounts: [%{"branch" => "0001", "number" => "1234567", "digit" => "0"}],
             configuration: %{"credit_card" => %{"max_installments" => "12"}}
           } = account

    # The account-info example writes the split id as "d"; readers get "id".
    assert [%{"id" => "937D2E09", "split_id" => "F81629A2", "pix_cents" => 109}] = account.splits
    assert account.body["subaccounts_negative_balance_total"] == "R$100,00"

    # A fresh, unverified subaccount: null configuration, nothing verified yet,
    # a balance field simply absent.
    Req.Test.expect(Iugu.Client, fn conn ->
      Req.Test.json(conn, %{
        "id" => "ACC",
        "name" => "Loja Ana",
        "is_verified?" => false,
        "can_receive?" => false,
        "last_verification_request_status" => nil,
        "configuration" => nil,
        "informations" => nil,
        "permissions" => ["owner"],
        "balance" => "R$ 0,00",
        "splits" => []
      })
    end)

    assert {:ok,
            %{
              verified?: false,
              can_receive?: false,
              balance_cents: 0,
              balance_available_for_withdraw_cents: nil,
              configuration: nil,
              splits: []
            }} = Iugu.get_account("ACC", api_token: @subaccount_token)

    # A balance in a shape nobody documented is nil, never zero, so the day
    # Iugu changes the format it shows up instead of reading as "no money".
    Req.Test.expect(Iugu.Client, fn conn ->
      Req.Test.json(conn, %{"id" => "ACC", "balance" => 58.03})
    end)

    assert {:ok, %{balance_cents: nil}} = Iugu.get_account("ACC", api_token: @subaccount_token)

    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"errors" => "Account Not Found"})
    end)

    assert {:error, %Error{kind: :not_found, messages: ["Account Not Found"]}} =
             Iugu.get_account("MISSING", api_token: @subaccount_token)
  end

  test "sends the KYC with the user_token for a natural person and a legal entity, converting the revenue, and refuses an incomplete payload before calling Iugu" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/accounts/ACC/request_verification"
      # The one route that takes the user_token while the account is still
      # unverified; no signature headers are declared for it.
      assert_basic(conn, @user_token)
      assert_unsigned(conn)

      assert body["data"]["person_type"] == "Pessoa Física"
      assert body["data"]["cpf"] == "12345678909"
      assert body["data"]["bank"] == "Itaú"
      assert body["data"]["estimated_revenue"] == "3500.00"
      refute Map.has_key?(body["data"], "estimated_revenue_cents")

      assert body["files"] == %{
               "identification_front" => "data:image/jpeg;base64,FRONT",
               "identification_back" => "data:image/jpeg;base64,BACK",
               "selfie" => "data:image/jpeg;base64,SELFIE"
             }

      Req.Test.json(conn, %{
        "id" => "FBB9275622CB4258A93A886C60B917EC",
        "account_id" => "ACC",
        "data" => Map.put(body["data"], "bank_ispb", "60701190"),
        "created_at" => "2026-01-23T15:08:01-03:00"
      })
    end)

    assert {:ok,
            %{"id" => "FBB9275622CB4258A93A886C60B917EC", "data" => %{"bank_ispb" => "60701190"}}} =
             Iugu.request_account_verification(
               "ACC",
               natural_person_data(),
               natural_person_files(),
               api_token: @user_token
             )

    # A legal entity with atom keys, the social contract and the revenue
    # already in the documented string format.
    expect_request(fn conn, body ->
      assert body["data"]["person_type"] == "Pessoa Jurídica"
      assert body["data"]["cnpj"] == "89814893000112"
      assert body["data"]["resp_cpf"] == "736.858.020-97"
      assert body["data"]["estimated_revenue"] == "100.00"
      assert Map.keys(body["files"]) == ["identification", "selfie", "social_contract"]

      Req.Test.json(conn, %{"id" => "VERIFICATION"})
    end)

    assert {:ok, %{"id" => "VERIFICATION"}} =
             Iugu.request_account_verification(
               "ACC",
               legal_entity_data(),
               legal_entity_files(),
               api_token: @user_token
             )

    # Each of these would be a 422 from Iugu, or a rejection days later. No
    # stub is standing, so the refusal is also proven to skip the network.
    refused = [
      {Map.delete(natural_person_data(), "cpf"), natural_person_files(), ~r/cpf/},
      {Map.delete(natural_person_data(), "telephone"), natural_person_files(), ~r/telephone/},
      {Map.put(natural_person_data(), "person_type", "PF"), natural_person_files(),
       ~r/person_type/},
      {Map.put(natural_person_data(), "account_type", "cc"), natural_person_files(),
       ~r/account_type/},
      {Map.put(natural_person_data(), "price_range", "R$ 100"), natural_person_files(),
       ~r/price_range/},
      {Map.put(natural_person_data(), "website", "www.loja.com"), natural_person_files(),
       ~r/website/},
      {Map.delete(legal_entity_data(), :company_name), legal_entity_files(), ~r/company_name/},
      {natural_person_data(), Map.delete(natural_person_files(), "selfie"), ~r/selfie/},
      {natural_person_data(), Map.delete(natural_person_files(), "identification_back"),
       ~r/identification/},
      {legal_entity_data(), Map.delete(legal_entity_files(), :social_contract),
       ~r/contrato social/},
      {natural_person_data(), Map.put(natural_person_files(), "passport", "data:..."),
       ~r/passport/}
    ]

    for {data, files, expected_message} <- refused do
      assert {:error,
              %Error{
                kind: :validation,
                status: nil,
                path: "/v1/accounts/ACC/request_verification",
                messages: [message]
              }} = Iugu.request_account_verification("ACC", data, files, api_token: @user_token)

      assert message =~ expected_message
    end

    # The lists those refusals are checked against are public, so a form can
    # offer only what the route takes.
    assert "Pessoa Física" in Iugu.person_types()
    refute "PF" in Iugu.person_types()
    assert "Corrente" in Iugu.verification_account_types()
    refute "cc" in Iugu.verification_account_types()
    assert "Até R$ 100,00" in Iugu.price_ranges()
    refute "R$ 100" in Iugu.price_ranges()
    assert "selfie" in Iugu.document_kinds()
    refute "passport" in Iugu.document_kinds()

    # The second call after a 200 is Iugu's to refuse, per field.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{
        "errors" => %{"account" => ["there's already a pending verification for this account"]}
      })
    end)

    assert {:error,
            %Error{
              kind: :validation,
              status: 422,
              fields: %{"account" => ["there's already a pending verification for this account"]}
            }} =
             Iugu.request_account_verification(
               "ACC",
               natural_person_data(),
               natural_person_files(),
               api_token: @user_token
             )
  end

  test "follows the documents: lists them, filters a status locally, and resends only the file the fraud team asked for" do
    documents = [
      %{"kind" => "selfie", "status" => "approved"},
      %{"kind" => "identification", "status" => "requested"}
    ]

    Req.Test.expect(Iugu.Client, 2, fn conn ->
      assert conn.method == "GET"
      # Singular "account", unlike every other route of the area.
      assert conn.request_path == "/v1/account/documents"
      assert conn.query_string == ""
      assert_basic(conn, @subaccount_token)

      Req.Test.json(conn, %{"items" => documents})
    end)

    assert {:ok, ^documents} = Iugu.list_account_documents(api_token: @subaccount_token)

    assert {:ok, [%{"kind" => "identification", "status" => "requested"}]} =
             Iugu.list_account_documents(status: "requested", api_token: @subaccount_token)

    # The master account is refused on this route.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"errors" => "Only subaccount are allowed"})
    end)

    assert {:error, %Error{kind: :validation, messages: ["Only subaccount are allowed"]}} =
             Iugu.list_account_documents()

    expect_request(fn conn, body ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/account/documents"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)
      assert body == %{"files" => %{"identification" => "data:application/pdf;base64,RG"}}

      Req.Test.json(conn, %{
        "items" => [%{"kind" => "identification", "status" => "pending_manual_analysis"}]
      })
    end)

    assert {:ok, [%{"kind" => "identification", "status" => "pending_manual_analysis"}]} =
             Iugu.resend_account_documents(%{identification: "data:application/pdf;base64,RG"},
               api_token: @subaccount_token
             )

    assert {:error, %Error{kind: :validation, status: nil, path: "/v1/account/documents"}} =
             Iugu.resend_account_documents(%{"rg" => "data:..."}, api_token: @subaccount_token)
  end

  test "configures the account with a signed whitelabel request, converting the anchor date and the minimum balance, and refuses a schedule Iugu would reject" do
    {private_key_pem, public_key} = generate_key_pair()

    expect_request_raw(fn conn, raw_body ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/v1/accounts/configuration"
      # Whitelabel: the master's key signs, the subaccount's token
      # authenticates and sits on line 2 of the signed document.
      assert_basic(conn, @subaccount_token)
      assert conn.query_params == %{"api_token" => @subaccount_token}

      assert Jason.decode!(raw_body) == %{
               "auto_withdraw" => true,
               "auto_withdraw_type" => "biweekly",
               "auto_withdraw_option" => 1,
               "auto_withdraw_anchor_date" => "2026-09-07",
               "customer_minimum_balance_cents" => "3000",
               "credit_card" => %{
                 "active" => true,
                 "max_installments" => 12,
                 "soft_descriptor" => "LOJAANA"
               }
             }

      assert_signed(conn, raw_body, public_key, @subaccount_token)

      Req.Test.json(conn, account_body(%{"auto_withdraw" => true}))
    end)

    assert {:ok, %{auto_withdraw: true, balance_cents: 10_000, verified?: true}} =
             Iugu.configure_account(
               %{
                 auto_withdraw: true,
                 auto_withdraw_type: "biweekly",
                 auto_withdraw_option: 1,
                 auto_withdraw_anchor_date: ~D[2026-09-07],
                 customer_minimum_balance_cents: 3_000,
                 credit_card: %{active: true, max_installments: 12, soft_descriptor: "LOJAANA"}
               },
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    refused = [
      {%{auto_withdraw_type: "fortnightly"}, ~r/auto_withdraw_type/},
      {%{auto_withdraw: true, auto_withdraw_type: "biweekly"}, ~r/auto_withdraw_anchor_date/},
      {%{auto_advance: true}, ~r/auto_advance_type/},
      {%{auto_advance: true, auto_advance_type: "weekly"}, ~r/auto_advance_option/},
      {%{payment_email_notification: true}, ~r/payment_email_notification_receiver/}
    ]

    for {settings, expected_message} <- refused do
      assert {:error,
              %Error{
                kind: :validation,
                status: nil,
                path: "/v1/accounts/configuration",
                messages: [message]
              }} =
               Iugu.configure_account(settings,
                 api_token: @subaccount_token,
                 signature_private_key: private_key_pem
               )

      assert message =~ expected_message
    end

    # A daily advance needs no option, so it goes through.
    expect_request_raw(fn conn, raw_body ->
      assert raw_body == ~s({"auto_advance":true,"auto_advance_type":"daily"})

      Req.Test.json(conn, account_body(%{"auto_advance" => true}))
    end)

    assert {:ok, %{auto_advance: true}} =
             Iugu.configure_account(%{auto_advance: true, auto_advance_type: "daily"},
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    # A signature failure is a 422 from Iugu, classified as validation.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"errors" => "Public Key Not Found"})
    end)

    assert {:error, %Error{kind: :validation, status: 422, messages: ["Public Key Not Found"]}} =
             Iugu.configure_account(%{fines: true, late_payment_fine: 2},
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )
  end

  test "updates a verified subaccount with the user_token, always carrying the website, and refuses a website without scheme" do
    expect_request(fn conn, body ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/accounts/ACC"
      assert_basic(conn, @user_token)
      assert_unsigned(conn)

      assert body == %{
               "website" => "https://loja.example",
               "subscriptions_billing_days" => 5,
               "auto_withdraw_type" => "monthly",
               "auto_withdraw_option" => 10,
               "auto_withdraw_anchor_date" => "2026-10-01"
             }

      Req.Test.json(conn, account_body(%{"marketplace" => false}))
    end)

    assert {:ok, %{marketplace?: false, verified?: true}} =
             Iugu.update_account(
               "ACC",
               %{
                 website: "https://loja.example",
                 subscriptions_billing_days: 5,
                 auto_withdraw_type: "monthly",
                 auto_withdraw_option: 10,
                 auto_withdraw_anchor_date: ~D[2026-10-01]
               },
               api_token: @user_token
             )

    # `website` is in the route's required list since 2026-06-08, so a
    # partial update without it is refused here rather than as a 422 there.
    for attrs <- [%{subscriptions_billing_days: 5}, %{website: "loja.example"}, %{website: ""}] do
      assert {:error, %Error{kind: :validation, status: nil, path: "/v1/accounts/ACC"}} =
               Iugu.update_account("ACC", attrs, api_token: @user_token)
    end

    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"errors" => "Account Not Found"})
    end)

    assert {:error, %Error{kind: :not_found}} =
             Iugu.update_account("MISSING", %{website: "https://loja.example"},
               api_token: @user_token
             )
  end

  test "switches Pix on and off with the subaccount token and surfaces Iugu's refusal of a second activation" do
    expect_request(fn conn, body ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/payments/pix"
      assert body == %{"enable" => true}
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      Req.Test.json(conn, %{"success" => true})
    end)

    assert {:ok, %{"success" => true}} = Iugu.set_account_pix(true, api_token: @subaccount_token)

    expect_request(fn conn, body ->
      assert body == %{"enable" => false}

      Req.Test.json(conn, %{"success" => true})
    end)

    assert {:ok, %{"success" => true}} = Iugu.set_account_pix(false, api_token: @subaccount_token)

    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"errors" => %{"base" => ["Conta já possui Pix ativo"]}})
    end)

    assert {:error, %Error{kind: :validation, fields: %{"base" => ["Conta já possui Pix ativo"]}}} =
             Iugu.set_account_pix(true, api_token: @subaccount_token)
  end

  test "changes the bank domicile with a signed request carrying the COMPE code, lists the requests, and refuses what the route would reject" do
    {private_key_pem, public_key} = generate_key_pair()

    expect_request_raw(fn conn, raw_body ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/v1/bank_verification"
      assert_basic(conn, @subaccount_token)
      assert conn.query_params == %{"api_token" => @subaccount_token}

      assert Jason.decode!(raw_body) == %{
               "agency" => "0001",
               "account" => "12345678-9",
               "account_type" => "cc",
               "bank" => "341",
               "automatic_validation" => true
             }

      assert_signed(conn, raw_body, public_key, @subaccount_token)

      Req.Test.json(conn, %{"success" => true})
    end)

    assert {:ok, %{"success" => true}} =
             Iugu.verify_bank_account(
               %{
                 agency: "0001",
                 account: "12345678-9",
                 account_type: "cc",
                 bank: "341",
                 automatic_validation: true
               },
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    # The verification route takes "Corrente" and "Itaú"; this one takes "cc"
    # and "341", and mixing them up is the most likely 422 of the area.
    assert "cc" in Iugu.bank_account_types()
    refute "Corrente" in Iugu.bank_account_types()

    refused = [
      {%{agency: "0001", account: "1-0", account_type: "Corrente", bank: "341"},
       ~r/account_type/},
      {%{agency: "0001", account: "1-0", account_type: "cc", bank: "Itaú"}, ~r/COMPE/},
      {%{agency: "0001", account_type: "cc", bank: "341"}, ~r/account/}
    ]

    for {bank_account, expected_message} <- refused do
      assert {:error,
              %Error{
                kind: :validation,
                status: nil,
                path: "/v1/bank_verification",
                messages: [message]
              }} =
               Iugu.verify_bank_account(bank_account,
                 api_token: @subaccount_token,
                 signature_private_key: private_key_pem
               )

      assert message =~ expected_message
    end

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/bank_verification"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      Req.Test.json(conn, [
        %{
          "id" => "00000000000000000000000000000000",
          "status" => "accepted",
          "account" => "12345678-9",
          "agency" => "0001",
          "operation" => nil,
          "feedback" => nil,
          "bank" => "Itaú"
        }
      ])
    end)

    assert {:ok, [%{"status" => "accepted", "bank" => "Itaú"}]} =
             Iugu.list_bank_verifications(api_token: @subaccount_token)

    # The 422 of this route is declared text/plain while carrying JSON.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("text/plain")
      |> Plug.Conn.send_resp(422, ~s({"errors":{"account_type":["is invalid"]}}))
    end)

    assert {:error,
            %Error{kind: :validation, status: 422, fields: %{"account_type" => ["is invalid"]}}} =
             Iugu.verify_bank_account(
               %{agency: "0001", account: "12345678-9", account_type: "cpg", bank: "341"},
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )
  end

  test "requests a withdraw signed as the account, sending reais with two decimals, never retrying, and refusing less than R$ 5,00" do
    {private_key_pem, public_key} = generate_key_pair()

    expect_request_raw(fn conn, raw_body ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/v1/accounts/ACC/request_withdraw"
      assert_basic(conn, @subaccount_token)
      assert conn.query_params == %{"api_token" => @subaccount_token}
      # The only Iugu route priced in reais: 2.550 cents leave as 25.5.
      assert raw_body == ~s({"amount":25.5})
      assert_signed(conn, raw_body, public_key, @subaccount_token)

      Req.Test.json(conn, %{
        "id" => "9E75E035E9DF4BF18ED7EE6A7AC1DC12",
        "status" => "accepted",
        "receipt_url" => "https://comprovantes.iugu.com/9e75e035"
      })
    end)

    assert {:ok, %{"id" => "9E75E035E9DF4BF18ED7EE6A7AC1DC12", "status" => "accepted"}} =
             Iugu.request_withdraw("ACC", 2_550,
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    expect_request_raw(fn conn, raw_body ->
      assert Jason.decode!(raw_body) == %{
               "amount" => 5.0,
               "custom_variables" => [%{"name" => "origem", "value" => "meu-app"}]
             }

      Req.Test.json(conn, %{"id" => "WITHDRAW", "status" => "pending"})
    end)

    assert {:ok, %{"status" => "pending"}} =
             Iugu.request_withdraw("ACC", 500,
               custom_variables: [%{name: "origem", value: "meu-app"}],
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    assert {:error,
            %Error{kind: :validation, status: nil, path: "/v1/accounts/ACC/request_withdraw"}} =
             Iugu.request_withdraw("ACC", 499,
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )

    # No Idempotency-Key on this route: a retry after a timeout can move the
    # money twice, so even an explicit retry option is ignored.
    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.request_withdraw("ACC", 500,
               api_token: @subaccount_token,
               signature_private_key: private_key_pem,
               retry: :transient,
               retry_delay: 0
             )

    assert attempts() == 1

    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"errors" => "Apenas disponível para o ambiente produção"})
    end)

    assert {:error, %Error{kind: :unauthorized}} =
             Iugu.request_withdraw("ACC", 500,
               api_token: "TEST-TOKEN",
               signature_private_key: private_key_pem
             )

    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"errors" => %{"amount" => ["maior que o saldo da conta."]}})
    end)

    assert {:error, %Error{kind: :validation, messages: ["amount: maior que o saldo da conta."]}} =
             Iugu.request_withdraw("ACC", 1_000_000,
               api_token: @subaccount_token,
               signature_private_key: private_key_pem
             )
  end

  test "lists the banks Iugu knows and every Bacen participant with their codes, and renews the user token" do
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/banks"
      assert_unsigned(conn)

      Req.Test.json(conn, [
        %{"compe" => "341", "name" => "Itaú", "ispb" => "60701190"},
        %{"compe" => "336", "name" => "C6 Bank", "ispb" => nil}
      ])
    end)

    assert {:ok, [%{"compe" => "341", "name" => "Itaú"}, %{"compe" => "336", "ispb" => nil}]} =
             Iugu.list_banks()

    # The Bacen-wide table: cooperatives without a COMPE code come with nil.
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/banks/list"
      assert_unsigned(conn)

      Req.Test.json(conn, [
        %{"compe" => nil, "name" => "COOP SICREDI COOPERJURIS", "ispb" => "08041950"},
        %{"compe" => "113", "name" => "NEON CTVM S.A.", "ispb" => "61723847"}
      ])
    end)

    assert {:ok, [%{"compe" => nil, "ispb" => "08041950"}, %{"compe" => "113"}]} =
             Iugu.list_all_banks()

    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/profile/renew_access_token"
      assert_basic(conn, @user_token)
      assert_unsigned(conn)
      assert body == %{}

      Req.Test.json(conn, %{"new_user_token" => "NEW-USER-TOKEN"})
    end)

    assert {:ok, "NEW-USER-TOKEN"} = Iugu.renew_user_token(api_token: @user_token)

    # The documented failure is a 400, not a 401, with "Unauthorized" inside.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"errors" => "Unauthorized"})
    end)

    assert {:error, %Error{kind: :validation, status: 400, messages: ["Unauthorized"]}} =
             Iugu.renew_user_token(api_token: @subaccount_token)

    Req.Test.expect(Iugu.Client, fn conn -> Req.Test.json(conn, %{}) end)

    assert {:error, %Error{kind: :unexpected, path: "/v1/profile/renew_access_token"}} =
             Iugu.renew_user_token(api_token: @user_token)
  end

  # The documented account-info example, trimmed to what the tests read, for
  # a verified subaccount with R$ 100,00 to withdraw.
  defp account_body(overrides) do
    Map.merge(
      %{
        "id" => "ACC",
        "name" => "Loja Ana",
        "can_receive?" => true,
        "is_verified?" => true,
        "last_verification_request_status" => "accepted",
        "last_verification_request_feedback" => nil,
        "marketplace" => false,
        "has_bank_address?" => true,
        "auto_withdraw" => false,
        "disabled_withdraw" => false,
        "auto_advance" => true,
        "auto_advance_type" => "daily",
        "balance" => "R$ 100,00",
        "balance_in_protest" => "R$ 0,00",
        "balance_available_for_withdraw" => "R$ 100,00",
        "protected_balance" => "R$ 0,00",
        "customer_minimum_balance_cents" => 3000,
        "payable_balance" => "R$ -10,00",
        "receivable_balance" => "R$ 20,00",
        "commission_balance" => "R$ 0,00",
        "bank_accounts" => [%{"branch" => "0001", "number" => "1234567", "digit" => "0"}],
        "configuration" => %{"credit_card" => %{"max_installments" => "12"}},
        "splits" => [
          %{
            "d" => "937D2E09",
            "split_id" => "F81629A2",
            "recipient_account_id" => "MASTER",
            "pix_cents" => 109,
            "permit_aggregated" => true
          }
        ]
      },
      overrides
    )
  end

  defp natural_person_data do
    %{
      "price_range" => "Até R$ 100,00",
      "physical_products" => false,
      "business_type" => "Loja de roupas",
      "person_type" => "Pessoa Física",
      "politically_exposed_person" => false,
      "automatic_transfer" => false,
      "cpf" => "12345678909",
      "name" => "Ana Souza",
      "street" => "Rua das Flores",
      "number" => "10",
      "district" => "Centro",
      "cep" => "01310-100",
      "city" => "São Paulo",
      "state" => "SP",
      "telephone" => "5511971111111",
      "estimated_revenue_cents" => 350_000,
      "bank" => "Itaú",
      "bank_ag" => "9999",
      "account_type" => "Corrente",
      "bank_cc" => "999999999-1",
      "website" => "https://loja.example"
    }
  end

  defp natural_person_files do
    %{
      "identification_front" => "data:image/jpeg;base64,FRONT",
      "identification_back" => "data:image/jpeg;base64,BACK",
      "selfie" => "data:image/jpeg;base64,SELFIE"
    }
  end

  defp legal_entity_data do
    %{
      price_range: "Entre R$ 100,00 e R$ 500,00",
      physical_products: false,
      business_type: "Meu negócio",
      person_type: "Pessoa Jurídica",
      politically_exposed_person: false,
      automatic_transfer: false,
      cnpj: "89814893000112",
      company_name: "Minha empresa",
      resp_name: "Nome do Resp",
      resp_cpf: "736.858.020-97",
      street: "Av. das Nações Unidas",
      number: "12495",
      district: "Cidade Monções",
      cep: "04578-000",
      city: "São Paulo",
      state: "SP",
      telephone: "5511971111111",
      estimated_revenue: "100.00",
      bank: "Itaú",
      bank_ag: "9999",
      account_type: "Corrente",
      bank_cc: "999999999-D",
      website: "https://www.exemplo.com/"
    }
  end

  defp legal_entity_files do
    %{
      identification: "data:application/pdf;base64,CNH",
      selfie: "data:image/jpeg;base64,SELFIE",
      social_contract: "data:application/pdf;base64,CONTRATO"
    }
  end
end
