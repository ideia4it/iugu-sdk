defmodule Iugu.PaymentTokenTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @account_id "A1B2C3D4E5F60718293A4B5C6D7E8F90"

  test "tokenizes a card with no API token on the wire, normalizes the answer, and refuses locally what the route would reject" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/payment_token"
      # "A API de Criação de Token não utiliza a autenticação via api_token":
      # the account_id in the body is the whole identity.
      assert Plug.Conn.get_req_header(conn, "authorization") == []
      assert Plug.Conn.get_req_header(conn, "signature") == []

      assert body == %{
               "account_id" => @account_id,
               "method" => "credit_card",
               "test" => true,
               "data" => %{
                 "number" => "4111 1111 1111 1111",
                 "verification_value" => "123",
                 "first_name" => "Ana",
                 "last_name" => "Silva",
                 "month" => "01",
                 "year" => "2030"
               }
             }

      Req.Test.json(conn, %{
        "id" => "ca9f3aa5-4df1-4a4c-9145-81641f1b4f6b",
        "method" => "credit_card",
        "extra_info" => %{
          "bin" => "411111",
          "year" => 2030,
          "month" => 1,
          "brand" => "VISA",
          "holder_name" => "ANA SILVA",
          "display_number" => "XXXX-XXXX-XXXX-1111"
        },
        "test" => true
      })
    end)

    assert {:ok,
            %{
              id: "ca9f3aa5-4df1-4a4c-9145-81641f1b4f6b",
              method: "credit_card",
              test?: true,
              brand: "VISA",
              bin: "411111",
              holder_name: "ANA SILVA",
              display_number: "XXXX-XXXX-XXXX-1111",
              month: 1,
              year: 2030,
              body: %{"id" => _id}
            }} =
             Iugu.create_payment_token(
               @account_id,
               %{
                 number: "4111 1111 1111 1111",
                 verification_value: "123",
                 first_name: "Ana",
                 last_name: "Silva",
                 month: 1,
                 year: 2030
               },
               test: true
             )

    # A live token: no test flag in the body, string month and year pass
    # through, and the one recipe's two-digit year is refused before the call.
    expect_request(fn conn, body ->
      refute Map.has_key?(body, "test")
      assert body["data"]["month"] == "12"
      assert body["data"]["year"] == "2030"

      Req.Test.json(conn, %{"id" => "live-token", "method" => "credit_card", "test" => false})
    end)

    valid = Iugu.test_card_data(:master_success)

    assert {:ok, %{id: "live-token", test?: false, brand: nil, month: nil}} =
             Iugu.create_payment_token(@account_id, valid)

    refused = [
      {Map.delete(valid, "verification_value"), ~r/verification_value/},
      {Map.put(valid, "month", 13), ~r/month/},
      {Map.put(valid, "year", "30"), ~r/year/},
      {Map.put(valid, "number", "4111-1111-1111-1111"), ~r/number/}
    ]

    for {card, expected_message} <- refused do
      assert {:error,
              %Error{
                kind: :validation,
                status: nil,
                path: "/v1/payment_token",
                messages: [message]
              }} = Iugu.create_payment_token(@account_id, card)

      assert message =~ expected_message
    end

    # What Iugu refuses: a per-field 422 for the card, a 400 for the account,
    # and a 200 that is not a token.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{
        "errors" => %{"number" => ["is not a valid credit card number"], "year" => ["expired"]}
      })
    end)

    assert {:error,
            %Error{
              kind: :validation,
              status: 422,
              fields: %{"number" => ["is not a valid credit card number"], "year" => ["expired"]}
            }} = Iugu.create_payment_token(@account_id, Iugu.test_card_data(:amex_invalid))

    Req.Test.expect(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"errors" => "account_id invalido"})
    end)

    assert {:error, %Error{kind: :validation, status: 400, messages: ["account_id invalido"]}} =
             Iugu.create_payment_token("nope", valid)

    Req.Test.expect(Iugu.Client, fn conn -> Req.Test.json(conn, %{"ok" => true}) end)

    assert {:error, %Error{kind: :unexpected, path: "/v1/payment_token"}} =
             Iugu.create_payment_token(@account_id, valid)

    # The documented test cards, ready to feed create/3: Amex takes a
    # four-digit CVV, everything else three.
    assert Iugu.test_card(:visa_declined) == "4012888888881881"
    assert Iugu.test_card(:hipercard_success) == nil
    assert map_size(Iugu.test_cards()) == 9

    assert %{"number" => "378282246310005", "verification_value" => "1234"} =
             Iugu.test_card_data(:amex_success)

    assert %{"number" => "38520000023237", "verification_value" => "1234"} =
             Iugu.test_card_data(:diners_declined)

    assert_raise ArgumentError, ~r/hipercard_success/, fn ->
      Iugu.test_card_data(:hipercard_success)
    end
  end

  test "checks a card through Zero Auth and reads an approval, a refusal with its LR and an unsupported brand" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/zero_auth"

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("LIVE:")
             ]

      assert body == %{"token" => "tok-1"}

      Req.Test.json(conn, %{
        "zero_auth" => %{"code" => "00", "message" => "Transacao autorizada", "valid" => true}
      })
    end)

    assert {:ok, %{valid?: true, code: "00", message: "Transacao autorizada"}} =
             Iugu.zero_auth("tok-1", api_token: "LIVE")

    # The refusal is a 422, and the brand rejection has no valid key at all;
    # both are the issuer saying no, not us calling the API wrong.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{
        "zero_auth" => %{"code" => "54", "message" => "Autorizacao negada", "valid" => false}
      })
    end)

    assert {:error,
            %Error{
              kind: :declined,
              status: 422,
              lr: "54",
              messages: ["Autorizacao negada"],
              path: "/v1/zero_auth"
            }} = Iugu.zero_auth("tok-2")

    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"zero_auth" => %{"code" => "57", "message" => "Bandeira Inválida"}})
    end)

    assert {:error, %Error{kind: :declined, lr: "57", messages: ["Bandeira Inválida"]}} =
             Iugu.zero_auth("tok-3")

    # A 200 without valid: true is still not an approval.
    Req.Test.expect(Iugu.Client, fn conn ->
      Req.Test.json(conn, %{"zero_auth" => %{"code" => "05", "message" => "Nao autorizada"}})
    end)

    assert {:error, %Error{kind: :declined, status: 200, lr: "05"}} =
             Iugu.zero_auth("tok-4")

    # A missing token is our bug: a 400 without the errors envelope.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"token" => ["must be a kind of: String", "can't be blank"]})
    end)

    assert {:error, %Error{kind: :validation, status: 400, body: %{"token" => _reasons}}} =
             Iugu.zero_auth("")

    Req.Test.expect(Iugu.Client, fn conn -> Req.Test.json(conn, %{}) end)

    assert {:error, %Error{kind: :unexpected, path: "/v1/zero_auth"}} =
             Iugu.zero_auth("tok-5")
  end
end
