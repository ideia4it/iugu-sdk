defmodule Iugu.CustomerTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"
  @customer_id "6A7BE09792BA40CFB13AA504367E5E12"

  test "creates a customer as the subaccount with the documented conversions and refuses before the call what Iugu would reject" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/customers"
      assert_basic(conn, @subaccount_token)
      assert Plug.Conn.get_req_header(conn, "signature") == []

      assert body == %{
               "email" => "ana@exemplo.com",
               "name" => "Ana Silva",
               "notes" => "Cliente desde 2024",
               "phone" => "972312345",
               "phone_prefix" => "11",
               "cpf_cnpj" => "11343675030",
               "cc_emails" => "financeiro@loja.com, dono@loja.com",
               "zip_code" => "13056-344",
               "number" => "60",
               "street" => "Rua Antônio Nunes",
               "district" => "Dic I",
               "city" => "Campinas",
               "state" => "SP",
               "complement" => "APTO 1702",
               "custom_variables" => [%{"name" => "loja_id", "value" => "42"}]
             }

      Req.Test.json(conn, customer_body(%{}))
    end)

    assert {:ok, %{"id" => @customer_id, "default_payment_method_id" => nil} = customer} =
             Iugu.create_customer(
               %{
                 "city" => "Campinas",
                 email: "ana@exemplo.com",
                 name: "Ana Silva",
                 notes: "Cliente desde 2024",
                 phone: "972312345",
                 phone_prefix: "11",
                 cpf_cnpj: "11343675030",
                 cc_emails: ["financeiro@loja.com", "dono@loja.com"],
                 zip_code: "13056-344",
                 number: "60",
                 street: "Rua Antônio Nunes",
                 district: "Dic I",
                 state: "SP",
                 complement: "APTO 1702",
                 custom_variables: [%{name: "loja_id", value: "42"}]
               },
               api_token: @subaccount_token
             )

    assert Iugu.customer_default_payment_method_id(customer) == nil

    # Without an Idempotency-Key a timeout may have created the customer, so
    # nothing is retried even when asked for; with the key the header goes
    # out and the timeout is retried, Iugu answering a repeat with 409.
    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.create_customer(%{email: "ana@exemplo.com", name: "Ana Silva"},
               retry: :transient
             )

    assert attempts() == 1

    test_pid = self()

    Req.Test.expect(Iugu.Client, 2, fn conn ->
      send(test_pid, :iugu_attempt)
      assert Plug.Conn.get_req_header(conn, "idempotency-key") == ["cliente-42"]

      case attempts_so_far() do
        1 -> Req.Test.transport_error(conn, :timeout)
        _later -> Req.Test.json(conn, customer_body(%{}))
      end
    end)

    assert {:ok, %{"id" => @customer_id}} =
             Iugu.create_customer(%{email: "ana@exemplo.com", name: "Ana Silva"},
               idempotency_key: "cliente-42",
               retry_delay: 0,
               retry_log_level: false
             )

    assert attempts() == 2

    # Each of these is a documented 422; no stub is standing, so the refusal
    # is also proven to skip the network.
    valid = %{email: "ana@exemplo.com", name: "Ana Silva"}

    refused = [
      {Map.delete(valid, :email), ~r/email/},
      {Map.put(valid, :name, ""), ~r/name/},
      {Map.put(valid, :phone, "972312345"), ~r/phone_prefix/},
      {Map.put(valid, :zip_code, "13056-344"), ~r/number/}
    ]

    for {attrs, expected_message} <- refused do
      assert {:error,
              %Error{kind: :validation, status: nil, path: "/v1/customers", messages: [message]}} =
               Iugu.create_customer(attrs)

      assert message =~ expected_message
    end

    assert_raise ArgumentError, ~r/document/, fn ->
      Iugu.create_customer(Map.put(valid, :document, "11343675030"))
    end

    # What Iugu refuses comes back per field, the way the form needs it.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{
        "errors" => %{"email" => ["is invalid."], "street" => ["não pode ficar em branco."]}
      })
    end)

    assert {:error,
            %Error{
              kind: :validation,
              status: 422,
              fields: %{"email" => ["is invalid."], "street" => ["não pode ficar em branco."]}
            }} = Iugu.create_customer(valid)
  end

  test "reads, lists inside the documented windows, walks every page, updates, sets and unsets the default card, shares cards from the master and deletes" do
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/customers/#{@customer_id}"
      assert_basic(conn, "iugu-test-token")

      Req.Test.json(conn, customer_body(%{"default_payment_method_id" => "PM1"}))
    end)

    assert {:ok, customer} = Iugu.get_customer(@customer_id)
    assert Iugu.customer_default_payment_method_id(customer) == "PM1"

    # Iugu documents this not-found as a 400, not a 404; both read as such.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"errors" => "Customer Not Found"})
    end)

    assert {:error, %Error{kind: :validation, status: 400} = not_found} =
             Iugu.get_customer("MISSING")

    assert Iugu.customer_not_found?(not_found)
    assert Iugu.customer_not_found?(%Error{kind: :not_found, status: 404})

    refute Iugu.customer_not_found?(%Error{
             kind: :validation,
             status: 422,
             messages: ["email: is invalid."]
           })

    refute Iugu.customer_not_found?(%Error{kind: :unauthorized, status: 401})

    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/customers"
      assert_basic(conn, @subaccount_token)

      # DateTimes leave in the -03:00 form the docs show; limit is capped at
      # the route's 100.
      assert conn.query_params == %{
               "start" => "200",
               "limit" => "100",
               "created_at_from" => "2026-06-01T00:00:00-03:00",
               "created_at_to" => "2026-09-03T20:59:59-03:00",
               "updated_since" => "2026-08-01T10:00:00-03:00",
               "updated_until" => "2026-09-03T10:00:00-03:00",
               "query" => "ana@exemplo.com"
             }

      Req.Test.json(conn, %{"items" => [customer_body(%{})], "totalItems" => 57})
    end)

    assert {:ok,
            %{
              customers: [%{"id" => @customer_id}],
              page_info: %{start: 200, limit: 100, total_items: 57}
            }} =
             Iugu.list_customers(
               start: 200,
               limit: 500,
               created_at_from: ~U[2026-06-01 03:00:00Z],
               created_at_to: ~U[2026-09-03 23:59:59Z],
               updated_since: "2026-08-01T10:00:00-03:00",
               updated_until: ~U[2026-09-03 13:00:00Z],
               query: "ana@exemplo.com",
               api_token: @subaccount_token
             )

    # A query needs pagination ("necessário usar paginação"), so limit is
    # filled in; deep pagination without a date filter is the documented 400,
    # refused here instead.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{"query" => "Ana", "limit" => "100"}

      Req.Test.json(conn, %{"items" => [], "totalItems" => 0})
    end)

    assert {:ok, %{customers: [], page_info: %{start: 0, limit: 100, total_items: 0}}} =
             Iugu.list_customers(query: "Ana")

    assert {:error, %Error{kind: :validation, status: nil, messages: [deep_message]}} =
             Iugu.list_customers(start: 101)

    assert deep_message =~ "start > 100"

    # The stream needs the identifying filter for the same reason, then stops
    # on the short page and never trusts totalItems.
    assert_raise ArgumentError, ~r/updated_since ou created_at_from/, fn ->
      Iugu.stream_customers(limit: 2)
    end

    Req.Test.expect(Iugu.Client, 3, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["created_at_from"] == "2026-01-01T00:00:00-03:00"
      assert conn.query_params["limit"] == "2"

      items =
        case conn.query_params["start"] do
          "0" -> [customer_body(%{"id" => "A"}), customer_body(%{"id" => "B"})]
          "2" -> [customer_body(%{"id" => "C"}), customer_body(%{"id" => "D"})]
          "4" -> [customer_body(%{"id" => "E"})]
        end

      Req.Test.json(conn, %{"items" => items, "totalItems" => 2})
    end)

    assert ["A", "B", "C", "D", "E"] =
             [created_at_from: "2026-01-01T00:00:00-03:00", limit: 2]
             |> Iugu.stream_customers()
             |> Enum.map(& &1["id"])

    # Update sends only what changes; a variable is removed with _destroy.
    expect_request(fn conn, body ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/customers/#{@customer_id}"

      assert body == %{
               "notes" => "Mudou de bairro",
               "zip_code" => "01310-100",
               "number" => "1000",
               "custom_variables" => [%{"name" => "loja_id", "_destroy" => true}]
             }

      Req.Test.json(conn, customer_body(%{"notes" => "Mudou de bairro"}))
    end)

    assert {:ok, %{"notes" => "Mudou de bairro"}} =
             Iugu.update_customer(@customer_id, %{
               notes: "Mudou de bairro",
               zip_code: "01310-100",
               number: "1000",
               custom_variables: [%{name: "loja_id", _destroy: true}]
             })

    assert {:error, %Error{kind: :validation, status: nil, messages: [pair_message]}} =
             Iugu.update_customer(@customer_id, %{phone: "972312345"})

    assert pair_message =~ "phone_prefix"

    # Setting the default card is the PUT; unsetting it has to send an
    # explicit null, which is the one nil the SDK must not drop.
    expect_request(fn conn, body ->
      assert conn.method == "PUT"
      assert body == %{"default_payment_method_id" => "PM1"}
      Req.Test.json(conn, customer_body(%{"default_payment_method_id" => "PM1"}))
    end)

    assert {:ok, %{"default_payment_method_id" => "PM1"}} =
             Iugu.set_customer_default_payment_method(@customer_id, "PM1")

    expect_request_raw(fn conn, raw_body ->
      assert raw_body == ~s({"default_payment_method_id":null})
      Req.Test.json(conn, customer_body(%{}))
    end)

    assert {:ok, %{"default_payment_method_id" => nil}} =
             Iugu.set_customer_default_payment_method(@customer_id, nil)

    # Sharing: the subaccount's customer points at the master's customer,
    # with the subaccount's token.
    expect_request(fn conn, body ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/customers/SUB-CUS"
      assert_basic(conn, @subaccount_token)
      assert body == %{"proxy_payments_from_customer_id" => "MASTER-CUS"}

      Req.Test.json(
        conn,
        customer_body(%{"id" => "SUB-CUS", "proxy_payments_from_customer_id" => "MASTER-CUS"})
      )
    end)

    assert {:ok, %{"proxy_payments_from_customer_id" => "MASTER-CUS"}} =
             Iugu.share_customer_payment_methods_from("SUB-CUS", "MASTER-CUS",
               api_token: @subaccount_token
             )

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/customers/#{@customer_id}"

      Req.Test.json(conn, customer_body(%{}))
    end)

    assert {:ok, %{"id" => @customer_id}} = Iugu.delete_customer(@customer_id)

    # A delete that Iugu refuses (subscriptions attached) is a plain 400.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{})
    end)

    assert {:error, %Error{kind: :validation, status: 400}} = Iugu.delete_customer(@customer_id)
  end

  test "saves a card from a token as the default, lists, reads, renames and removes it, and reads the card data in every documented shape" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/customers/#{@customer_id}/payment_methods"
      assert_basic(conn, @subaccount_token)

      assert body == %{
               "description" => "Meu Master Roxinho",
               "token" => "ca9f3aa5-4df1-4a4c-9145-81641f1b4f6b",
               "set_as_default" => true
             }

      Req.Test.json(conn, payment_method_body(%{}))
    end)

    assert {:ok, %{"id" => "9F9977E32DC74DC18266FD02454AB4F5"} = payment_method} =
             Iugu.create_customer_payment_method(
               @customer_id,
               %{
                 description: "Meu Master Roxinho",
                 token: "ca9f3aa5-4df1-4a4c-9145-81641f1b4f6b",
                 set_as_default: true
               },
               api_token: @subaccount_token
             )

    assert %{
             brand: "Master",
             holder_name: "NOME NO KARTÃO",
             display_number: "XXXX-XXXX-XXXX-4444",
             bin: "555555",
             last_digits: "4444",
             month: 12,
             year: 2030,
             fingerprint: "39124eb1-9813-ee72-f5df-75725cd9a5c0",
             issuer: "Informação não disponivel",
             foreign_card?: true
           } = Iugu.payment_method_card(payment_method)

    # Both fields are required, and the token is single use: reusing one is
    # Iugu's 422, not ours.
    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.create_customer_payment_method(@customer_id, %{description: "Sem token"})

    assert message =~ "token"

    assert_raise ArgumentError, ~r/item_type/, fn ->
      Iugu.create_customer_payment_method(@customer_id, %{token: "t", item_type: "credit_card"})
    end

    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"errors" => %{"token" => ["Esse token já foi usado."]}})
    end)

    assert {:error, %Error{kind: :validation, fields: %{"token" => ["Esse token já foi usado."]}}} =
             Iugu.create_customer_payment_method(@customer_id, %{
               token: "ca9f3aa5-4df1-4a4c-9145-81641f1b4f6b",
               description: "De novo"
             })

    # The listing is a bare array, with the recipe's string year and month
    # and the Postgres-style "f".
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/customers/#{@customer_id}/payment_methods"

      Req.Test.json(conn, [
        payment_method_body(%{}),
        payment_method_body(%{
          "id" => "PM2",
          "data" => %{
            "brand" => "Visa",
            "holder_name" => "ANA SILVA",
            "display_number" => "XXXX-XXXX-XXXX-1111",
            "bin" => "411111",
            "year" => "2029",
            "month" => "5",
            "fingerprint" => "abc",
            "issuer" => "BANCO X",
            "foreign_card" => "f"
          }
        })
      ])
    end)

    assert {:ok, [%{"id" => "9F9977E32DC74DC18266FD02454AB4F5"}, %{"id" => "PM2"} = visa]} =
             Iugu.list_customer_payment_methods(@customer_id)

    assert %{brand: "Visa", month: 5, year: 2029, last_digits: "1111", foreign_card?: false} =
             Iugu.payment_method_card(visa)

    assert Iugu.payment_method_card(%{"id" => "PM3", "data" => nil}) == nil

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/customers/#{@customer_id}/payment_methods/PM2"

      Req.Test.json(conn, payment_method_body(%{"id" => "PM2"}))
    end)

    assert {:ok, %{"id" => "PM2"}} = Iugu.get_customer_payment_method(@customer_id, "PM2")

    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(404)
      |> Req.Test.json(%{"errors" => "Customer payment method Not Found"})
    end)

    assert {:error, %Error{kind: :not_found} = missing} =
             Iugu.get_customer_payment_method(@customer_id, "MISSING")

    assert Iugu.customer_not_found?(missing)

    expect_request(fn conn, body ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/customers/#{@customer_id}/payment_methods/PM2"
      assert body == %{"description" => "Visa da empresa"}

      Req.Test.json(
        conn,
        payment_method_body(%{"id" => "PM2", "description" => "Visa da empresa"})
      )
    end)

    assert {:ok, %{"description" => "Visa da empresa"}} =
             Iugu.update_customer_payment_method(@customer_id, "PM2", "Visa da empresa")

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/customers/#{@customer_id}/payment_methods/PM2"

      Req.Test.json(conn, payment_method_body(%{"id" => "PM2"}))
    end)

    assert {:ok, %{"id" => "PM2"}} = Iugu.delete_customer_payment_method(@customer_id, "PM2")
  end

  defp customer_body(overrides) do
    Map.merge(
      %{
        "id" => @customer_id,
        "email" => "ana@exemplo.com",
        "name" => "Ana Silva",
        "notes" => nil,
        "created_at" => "2025-04-03T12:04:38-03:00",
        "updated_at" => "2025-04-03T12:07:31-03:00",
        "cc_emails" => nil,
        "cpf_cnpj" => "11343675030",
        "zip_code" => "13056-344",
        "number" => "60",
        "complement" => "APTO 1702",
        "phone" => "972312345",
        "phone_prefix" => "11",
        "custom_variables" => [],
        "payment_methods" => [],
        "default_payment_method_id" => nil,
        "proxy_payments_from_customer_id" => nil,
        "city" => "Campinas",
        "state" => "SP",
        "district" => "Dic I",
        "street" => "Rua Antônio Nunes"
      },
      overrides
    )
  end

  defp payment_method_body(overrides) do
    Map.merge(
      %{
        "id" => "9F9977E32DC74DC18266FD02454AB4F5",
        "description" => "Meu Master Roxinho",
        "item_type" => "credit_card",
        "customer_id" => @customer_id,
        "data" => %{
          "brand" => "Master",
          "holder_name" => "NOME NO KARTÃO",
          "display_number" => "XXXX-XXXX-XXXX-4444",
          "bin" => "555555",
          "year" => 2030,
          "month" => 12,
          "last_digits" => "4444",
          "first_digits" => "555555",
          "masked_number" => "XXXX-XXXX-XXXX-4444",
          "fingerprint" => "39124eb1-9813-ee72-f5df-75725cd9a5c0",
          "issuer" => "Informação não disponivel",
          "card_type" => "Multiplo",
          "foreign_card" => "t"
        }
      },
      overrides
    )
  end
end
