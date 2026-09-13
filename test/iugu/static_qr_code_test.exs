defmodule Iugu.StaticQrCodeTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"
  @payload "00020126580014br.gov.bcb.pix013654f68fe2-bab3-4abb-abcf-2b6943ed3db65204000053039865406150.005802BR5922Bruna Cardoso da Silva6009Sao Paulo6226052228Uum08VxYqz50ronJ1x6v63047B5C"

  test "creates a fixed-amount QR for the counter, refuses a long description and a bad amount locally, then reads it back and lists every QR of the account" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/static_qr_codes"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)
      assert body == %{"amount_cents" => 15_000, "description" => "Corte e escova"}

      Req.Test.json(conn, %{
        "qr_code_id" => "4637B1FF558B4334968EA308D88B9DA1",
        "qr_code_payload" => @payload,
        "qr_code_pix_key" => "54f68fe2-bab3-4abb-abcf-2b6943ed3db6",
        "qr_code_amount_cents" => 15_000,
        "qr_code" => "https://faturas.iugu.com/static_qr_code/4637B1FF558B4334968EA308D88B9DA1",
        "qr_code_description" => "Corte e escova"
      })
    end)

    assert {:ok, qr_code} =
             Iugu.create_static_qr_code(%{amount_cents: 15_000, description: "Corte e escova"},
               api_token: @subaccount_token
             )

    assert %{
             id: "4637B1FF558B4334968EA308D88B9DA1",
             payload: @payload,
             pix_key: "54f68fe2-bab3-4abb-abcf-2b6943ed3db6",
             amount_cents: 15_000,
             url: "https://faturas.iugu.com/static_qr_code/4637B1FF558B4334968EA308D88B9DA1",
             description: "Corte e escova"
           } = qr_code

    # Without an amount the payer chooses how much to send.
    expect_request(fn conn, body ->
      assert body == %{}
      Req.Test.json(conn, %{"qr_code_id" => "OPEN", "qr_code_amount_cents" => nil})
    end)

    assert {:ok, %{id: "OPEN", amount_cents: nil}} =
             Iugu.create_static_qr_code(%{}, api_token: @subaccount_token)

    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.create_static_qr_code(%{description: String.duplicate("a", 26)},
               api_token: @subaccount_token
             )

    assert message =~ "25"

    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.create_static_qr_code(%{"amount_cents" => "150.00"},
               api_token: @subaccount_token
             )

    assert message =~ "amount_cents"

    assert_raise ArgumentError, fn ->
      Iugu.create_static_qr_code(%{amount: 100}, api_token: @subaccount_token)
    end

    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.create_static_qr_code(%{amount_cents: 100}, api_token: @subaccount_token)

    assert attempts() == 1

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/static_qr_codes/4637B1FF558B4334968EA308D88B9DA1"
      assert_basic(conn, @subaccount_token)

      Req.Test.json(conn, %{
        "qr_code_id" => "4637B1FF558B4334968EA308D88B9DA1",
        "qr_code_payload" => @payload,
        "qr_code_amount_cents" => 15_000
      })
    end)

    assert {:ok, %{id: "4637B1FF558B4334968EA308D88B9DA1", payload: @payload}} =
             Iugu.get_static_qr_code("4637B1FF558B4334968EA308D88B9DA1",
               api_token: @subaccount_token
             )

    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/static_qr_codes"
      assert conn.query_params == %{"start" => "0", "limit" => "100"}

      Req.Test.json(conn, %{
        "items" => [
          %{
            "qr_code_id" => "BE7E2B9ECEBA4A20AE141B06A9125FFC",
            "qr_code_amount_cents" => 23_400,
            "qr_code_description" => "Não pague esse QRCode."
          }
        ],
        "totalItems" => 7
      })
    end)

    assert {:ok, page} =
             Iugu.list_static_qr_codes(start: 0, limit: 500, api_token: @subaccount_token)

    assert [%{id: "BE7E2B9ECEBA4A20AE141B06A9125FFC", amount_cents: 23_400}] =
             page.static_qr_codes

    assert page.page_info == %{start: 0, limit: 100, total_items: 7}

    Req.Test.expect(Iugu.Client, 2, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params do
        %{"start" => "0", "limit" => "2"} ->
          Req.Test.json(conn, %{"items" => [%{"qr_code_id" => "1"}, %{"qr_code_id" => "2"}]})

        %{"start" => "2", "limit" => "2"} ->
          Req.Test.json(conn, %{"items" => [%{"qr_code_id" => "3"}]})
      end
    end)

    assert ["1", "2", "3"] =
             Iugu.stream_static_qr_codes(limit: 2, api_token: @subaccount_token)
             |> Enum.map(& &1.id)
  end
end
