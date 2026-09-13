defmodule Iugu.DepositTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"

  test "reads a deposit from the webhook id with sender and receiver regrouped, recognizes the 400 not found, and refunds a Pix without retrying" do
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/deposits/9E5FD9F9140546E7A00B585AEBEA2086"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      Req.Test.json(conn, %{
        "id" => "9E5FD9F9140546E7A00B585AEBEA2086",
        "status" => "accepted",
        "deposit_type" => "qrcode",
        "created_at" => "2024-02-22T14:12:48-03:00",
        "updated_at" => "2024-02-22T14:12:48-03:00",
        "amount_cents" => 50,
        "accepted_at" => "2024-02-22T14:12:48-03:00",
        "transfered_at" => "2024-02-22T14:12:48-03:00",
        "rejected_at" => nil,
        "receiver_account_branch" => "1",
        "receiver_account_number" => "3693443",
        "receiver_account_digit" => "0",
        "receiver_name" => "IUGU INSTITUICAO DE PAGAMENTO S.A.",
        "sender_account_bank" => "22896431",
        "sender_account_branch" => "1",
        "sender_account_number" => "132035103",
        "sender_account_digit" => nil,
        "sender_name" => "Nome de quem depositou.",
        "sender_document_number" => "6341492880",
        "sender_document_type" => "CPF",
        "account_id" => "27016E1AD888499A98994E781B6C3762",
        "amount" => "R$0,50",
        "receipt_url" => "https://comprovantes.iugu.com/9e5fd9f9"
      })
    end)

    assert {:ok, deposit} =
             Iugu.get_deposit("9E5FD9F9140546E7A00B585AEBEA2086", api_token: @subaccount_token)

    assert %{
             id: "9E5FD9F9140546E7A00B585AEBEA2086",
             status: "accepted",
             deposit_type: "qrcode",
             amount_cents: 50,
             account_id: "27016E1AD888499A98994E781B6C3762",
             receipt_url: "https://comprovantes.iugu.com/9e5fd9f9",
             accepted_at: "2024-02-22T14:12:48-03:00",
             rejected_at: nil,
             sender: %{
               name: "Nome de quem depositou.",
               document_number: "6341492880",
               document_type: "CPF",
               bank: "22896431",
               branch: "1",
               account_number: "132035103",
               account_digit: nil
             },
             receiver: %{
               name: "IUGU INSTITUICAO DE PAGAMENTO S.A.",
               branch: "1",
               account_number: "3693443",
               account_digit: "0",
               bank: nil
             }
           } = deposit

    assert deposit.body["amount"] == "R$0,50"

    # The reference documents the unknown id as a 400, not a 404.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"errors" => "Deposit Not Found"})
    end)

    assert {:error, %Error{kind: :validation, status: 400} = error} =
             Iugu.get_deposit("MISSING", api_token: @subaccount_token)

    assert Iugu.deposit_not_found?(error)

    Req.Test.expect(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"errors" => "Not Found"})
    end)

    assert {:error, error} = Iugu.get_deposit("MISSING", api_token: @subaccount_token)
    assert Iugu.deposit_not_found?(error)

    expect_request_raw(fn conn, raw_body ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/deposits/1ACAE09AFDAB4C6EBB15DC0DBF82CB8C/refund"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)
      assert raw_body == ""

      Req.Test.json(conn, %{
        "id" => "1ACAE09AFDAB4C6EBB15DC0DBF82CB8C",
        "status" => "processing_refund",
        "deposit_type" => "pix",
        "amount_cents" => 54_920,
        "amount" => "R$549.20",
        "sender_document_type" => "cpf"
      })
    end)

    assert {:ok, %{status: "processing_refund", deposit_type: "pix", amount_cents: 54_920}} =
             Iugu.refund_deposit("1ACAE09AFDAB4C6EBB15DC0DBF82CB8C", api_token: @subaccount_token)

    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"errors" => ["Não é possivel reembolsar este depósito."]})
    end)

    assert {:error, %Error{kind: :validation, status: 400, messages: [message]} = error} =
             Iugu.refund_deposit("1ACAE09AFDAB4C6EBB15DC0DBF82CB8C", api_token: @subaccount_token)

    assert message =~ "reembolsar"
    refute Iugu.deposit_not_found?(error)

    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.refund_deposit("1ACAE09AFDAB4C6EBB15DC0DBF82CB8C", api_token: @subaccount_token)

    assert attempts() == 1
  end

  test "lists the account's deposits with the limit capped at 1000 and streams all pages" do
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/deposits"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)
      assert conn.query_params == %{"start" => "0", "limit" => "1000"}

      Req.Test.json(conn, %{
        "items" => [
          %{
            "id" => "077CACD11FAC4679853D384C85E68375",
            "status" => "accepted",
            "deposit_type" => "qrcode",
            "amount_cents" => 5000,
            "sender_name" => "Nome de quem depositou.",
            "account_id" => "27016E1AD888499A98994E781B6C3762"
          },
          %{
            "id" => "71D74B5674594504841C1079F22FB42A",
            "status" => "refunded",
            "deposit_type" => "pix",
            "amount_cents" => 100
          }
        ]
      })
    end)

    assert {:ok, page} = Iugu.list_deposits(start: 0, limit: 5000, api_token: @subaccount_token)

    assert [
             %{
               id: "077CACD11FAC4679853D384C85E68375",
               amount_cents: 5000,
               sender: %{name: "Nome" <> _}
             },
             %{id: "71D74B5674594504841C1079F22FB42A", status: "refunded", deposit_type: "pix"}
           ] = page.deposits

    assert page.page_info == %{start: 0, limit: 1000, total_items: nil}

    Req.Test.expect(Iugu.Client, 2, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params do
        %{"start" => "0", "limit" => "2"} ->
          Req.Test.json(conn, %{"items" => [%{"id" => "1"}, %{"id" => "2"}]})

        %{"start" => "2", "limit" => "2"} ->
          Req.Test.json(conn, %{"items" => [%{"id" => "3"}]})
      end
    end)

    assert ["1", "2", "3"] =
             Iugu.stream_deposits(limit: 2, api_token: @subaccount_token) |> Enum.map(& &1.id)

    assert "refunded" in Iugu.deposit_statuses()
    assert Iugu.deposit_types() == ["pix", "qrcode", "ted"]
  end
end
