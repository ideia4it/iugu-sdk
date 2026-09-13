defmodule Iugu.PixKeyTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"

  test "shows the key registered in the DICT to the payer, checks every key's status before trusting it, and surfaces the production-only 401" do
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/pix/keys"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      Req.Test.json(conn, [
        %{
          "key" => "123e4f56-cce7-4255-b526-e0f33c3c3ce4",
          "name" => "Loja Ana",
          "created_at" => "2023-08-17T20:53:49.835Z",
          "start_date" => "2023-08-17T20:53:49.835Z",
          "type" => "evp"
        }
      ])
    end)

    assert {:ok,
            [
              %{
                key: "123e4f56-cce7-4255-b526-e0f33c3c3ce4",
                type: "evp",
                name: "Loja Ana",
                start_date: "2023-08-17T20:53:49.835Z"
              }
            ]} = Iugu.registered_pix_keys(api_token: @subaccount_token)

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/bank_account_pix_keys"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      Req.Test.json(conn, %{
        "pix_keys" => [
          %{
            "id" => "923B72F0DD2F42FD94CEA3E771C8363B",
            "pix_key" => "contato@lojaana.com.br",
            "pix_key_type" => "email",
            "created_at" => "2024-01-15T12:40:15-03:00",
            "status" => "active"
          },
          %{
            "id" => "0B4D1",
            "pix_key" => "+5511999999999",
            "pix_key_type" => "phone",
            "status" => "processing"
          }
        ]
      })
    end)

    assert {:ok,
            [
              %{
                id: "923B72F0DD2F42FD94CEA3E771C8363B",
                key: "contato@lojaana.com.br",
                type: "email",
                status: "active"
              },
              %{key: "+5511999999999", type: "phone", status: "processing"}
            ]} = Iugu.list_pix_keys(api_token: @subaccount_token)

    # With a test token the route exists but refuses: production only.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(401)
      |> Req.Test.json(%{"errors" => "Apenas disponível para o ambiente produção"})
    end)

    assert {:error,
            %Error{kind: :unauthorized, messages: ["Apenas disponível para o ambiente produção"]}} =
             Iugu.registered_pix_keys(api_token: "TEST-TOKEN")

    Req.Test.expect(Iugu.Client, fn conn -> Req.Test.json(conn, %{}) end)

    assert {:ok, []} = Iugu.list_pix_keys(api_token: @subaccount_token)
  end
end
