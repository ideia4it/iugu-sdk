defmodule Iugu.ErrorTest do
  use ExUnit.Case, async: true

  alias Iugu.Error

  test "reads every documented Iugu error shape into a kind, the messages, the fields and a line for the log" do
    # The three shapes of `errors`: a string, a list and a map of fields.
    assert response_error(404, %{"errors" => "Account Not Found"}).messages == [
             "Account Not Found"
           ]

    assert response_error(400, %{
             "errors" => [
               "Description não pode ficar em branco",
               "Api type não pode ficar em branco"
             ]
           }).messages == [
             "Description não pode ficar em branco",
             "Api type não pode ficar em branco"
           ]

    invoice =
      response_error(422, %{
        "errors" => %{
          "items.price_cents" => ["não pode ficar em branco"],
          "due_date" => ["não pode ficar em branco", "não pode estar no passado"]
        }
      })

    # A 422 on invoice creation is per field, so the form needs the map and
    # the log needs one stable line.
    assert invoice.fields == %{
             "due_date" => ["não pode ficar em branco", "não pode estar no passado"],
             "items.price_cents" => ["não pode ficar em branco"]
           }

    assert invoice.messages == [
             "due_date: não pode ficar em branco",
             "due_date: não pode estar no passado",
             "items.price_cents: não pode ficar em branco"
           ]

    # The transfer between accounts wraps the same per-field map in "message"
    # instead of "errors"; an insufficient balance must read the same way.
    transfer =
      response_error(422, %{
        "message" => %{
          "receiver_account" => ["não encontrado"],
          "amount_cents" => ["Saldo insuficiente"]
        }
      })

    assert transfer.fields == %{
             "amount_cents" => ["Saldo insuficiente"],
             "receiver_account" => ["não encontrado"]
           }

    assert transfer.messages == [
             "amount_cents: Saldo insuficiente",
             "receiver_account: não encontrado"
           ]

    # A field whose messages are not a list still reads.
    assert response_error(422, %{"errors" => %{"base" => "Conta já possui Pix ativo"}}).fields ==
             %{"base" => ["Conta já possui Pix ativo"]}

    # The other shapes: success false with a message, a raw string body from a
    # proxy, and JSON declared as text/plain, which Req leaves undecoded.
    assert response_error(400, %{"success" => false, "message" => "Pix must be enabled"}).messages ==
             ["Pix must be enabled"]

    assert response_error(502, "<html>Bad Gateway</html>").messages == [
             "<html>Bad Gateway</html>"
           ]

    text_plain = response_error(422, ~s({"errors":{"account_type":["is invalid"]}}))

    assert text_plain.fields == %{"account_type" => ["is invalid"]}
    assert text_plain.messages == ["account_type: is invalid"]

    # And no message at all, rather than raising, for a shape we cannot read.
    assert response_error(400, %{}).messages == []
    assert response_error(400, %{}).fields == %{}
    assert response_error(500, nil).messages == []
    assert response_error(500, "").messages == []
    assert response_error(400, %{"errors" => ""}).messages == []
    assert response_error(400, %{"errors" => [%{"code" => 42}]}).messages == [~s(%{"code" => 42})]

    # The status separates the failures that call for different investigations.
    assert response_error(401, %{}).kind == :unauthorized
    assert response_error(403, %{}).kind == :forbidden
    assert response_error(404, %{}).kind == :not_found
    assert response_error(429, %{}).kind == :rate_limited
    assert response_error(400, %{}).kind == :validation
    assert response_error(409, %{}).kind == :validation
    assert response_error(422, %{}).kind == :validation
    assert response_error(503, %{}).kind == :server
    assert response_error(302, %{}).kind == :unexpected

    # The line that reaches the log names the kind, the status and the path.
    assert Exception.message(response_error(401, %{"errors" => "Unauthorized"})) ==
             "Iugu unauthorized (HTTP 401) em /v1/accounts/ACC: Unauthorized"

    assert Exception.message(invoice) =~
             "due_date: não pode ficar em branco; due_date: não pode estar no passado"

    assert Exception.message(response_error(500, nil)) =~ "sem mensagem"

    # Raising while formatting an error hides the error.
    assert Exception.message(%Error{kind: :unexpected}) =~ "em ?:"
  end

  test "builds the failures that never reached Iugu and retries only what cannot double a side effect" do
    validation =
      Error.validation("nome da subconta não pode ter dígitos", "/v1/marketplace/create_account")

    assert validation.kind == :validation
    assert validation.status == nil

    assert Exception.message(validation) ==
             "Iugu validation em /v1/marketplace/create_account: nome da subconta não pode ter dígitos"

    # A card refusal is not an HTTP failure: Iugu answers 200 and the issuer
    # said no, so the line has to carry the LR code the support desk asks for.
    declined =
      Error.declined(%{"success" => false, "LR" => "51"}, "/v1/charge",
        lr: "51",
        message: "Não Autorizado"
      )

    assert declined.kind == :declined
    assert declined.status == 200
    assert declined.lr == "51"

    assert Exception.message(declined) ==
             "Iugu declined (HTTP 200) em /v1/charge: Não Autorizado (LR 51)"

    assert Error.declined(%{}, "/v1/zero_auth", lr: 54, status: 422).lr == "54"
    assert Exception.message(Error.declined(%{}, "/v1/charge")) =~ "sem mensagem"

    # A transport failure never had a status either, so none is printed.
    transport = Error.from_exception(%Req.TransportError{reason: :timeout}, "/v1/invoices")

    assert transport.kind == :transport
    assert Exception.message(transport) == "Iugu transport em /v1/invoices: timeout"

    # A typo in the retriable list would silently turn a 401 into an infinite
    # retry loop against the test-mode rate limit.
    for kind <- [:rate_limited, :server, :transport] do
      assert Error.retriable?(%Error{kind: kind}), "esperava #{kind} retriável"
    end

    for kind <- [:unauthorized, :forbidden, :not_found, :validation, :declined, :unexpected] do
      refute Error.retriable?(%Error{kind: kind}), "esperava #{kind} não retriável"
    end
  end

  defp response_error(status, body) do
    Error.from_response(%Req.Response{status: status, body: body}, "/v1/accounts/ACC")
  end
end
