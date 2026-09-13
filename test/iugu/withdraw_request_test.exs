defmodule Iugu.WithdrawRequestTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"

  test "follows a withdraw from the webhook id: reads it in cents, lists the account's withdraws by status and custom variable, and refuses an unknown status locally" do
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/withdraw_requests/530706A3862D4BB49C8AC9637B850CDE"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      Req.Test.json(conn, %{
        "id" => "530706A3862D4BB49C8AC9637B850CDE",
        "status" => "pending",
        "created_at" => "2015-11-26T10:02:23-02:00",
        "updated_at" => "2015-11-26T10:02:23-02:00",
        "reference" => nil,
        "amount" => "R$ 10,00",
        "account_name" => "Loja Ana",
        "account_id" => "A682CECA59D74527B984CA529D7C2ED4",
        "feedback" => nil,
        "bank_address" => %{
          "bank" => "Bradesco",
          "bank_cc" => "11231-2",
          "bank_ag" => "1234",
          "account_type" => "Corrente"
        }
      })
    end)

    assert {:ok, withdraw} =
             Iugu.get_withdraw_request("530706A3862D4BB49C8AC9637B850CDE",
               api_token: @subaccount_token
             )

    assert %{
             id: "530706A3862D4BB49C8AC9637B850CDE",
             status: "pending",
             amount_cents: 1_000,
             feedback: nil,
             account_id: "A682CECA59D74527B984CA529D7C2ED4",
             account_name: "Loja Ana",
             paying_at: nil,
             receipt_url: nil,
             agreement_effect: false,
             bank_address: %{"bank" => "Bradesco", "account_type" => "Corrente"},
             custom_variables: []
           } = withdraw

    assert withdraw.body["created_at"] == "2015-11-26T10:02:23-02:00"

    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/withdraw_requests"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      assert conn.query_params == %{
               "status" => "rejected",
               "custom_variables_name" => "origem",
               "custom_variables_value" => "meu-app"
             }

      Req.Test.json(conn, %{
        "items" => [
          %{
            "id" => "4194D625A1894FAFAB2478DC333DAF0D",
            "status" => "rejected",
            "created_at" => "2024-06-13T09:10:55-03:00",
            "updated_at" => "2024-06-14T10:11:03-03:00",
            "reference" => "core:transfer:17ctElpMA77H9gJvWtexma",
            "feedback" => "Código: '2' - Agência ou Conta Destinatária do Crédito Inválida",
            "paying_at" => "2024-06-14",
            "custom_variables" => [%{"name" => "origem", "value" => "meu-app"}],
            "amount" => "R$ 5,00",
            "account_name" => "Loja Ana",
            "account_id" => "44C5DC6376804D1FA792CBCA382105C1",
            "receipt_url" => "https://comprovantes.iugu.com/4194d625",
            "agreement_effect" => true,
            "bank_address" => %{"bank" => "Santander", "account_type" => "Corrente"}
          }
        ],
        "totalItems" => 2
      })
    end)

    assert {:ok, page} =
             Iugu.list_withdraw_requests(
               status: "rejected",
               custom_variables_name: "origem",
               custom_variables_value: "meu-app",
               api_token: @subaccount_token
             )

    assert [
             %{
               id: "4194D625A1894FAFAB2478DC333DAF0D",
               status: "rejected",
               amount_cents: 500,
               feedback: "Código: '2' - Agência ou Conta Destinatária do Crédito Inválida",
               paying_at: "2024-06-14",
               receipt_url: "https://comprovantes.iugu.com/4194d625",
               agreement_effect: true,
               reference: "core:transfer:17ctElpMA77H9gJvWtexma",
               custom_variables: [%{"name" => "origem", "value" => "meu-app"}]
             }
           ] = page.withdraw_requests

    assert page.page_info == %{start: 0, limit: nil, total_items: 2}

    # Pagination is not documented on this route; when asked for, it goes out.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params == %{"start" => "100", "limit" => "50"}

      Req.Test.json(conn, %{"items" => [], "totalItems" => 2})
    end)

    assert {:ok, %{withdraw_requests: [], page_info: %{start: 100, limit: 50}}} =
             Iugu.list_withdraw_requests(start: 100, limit: 50, api_token: @subaccount_token)

    assert {:error, %Error{kind: :validation, status: nil, path: "/v1/withdraw_requests"}} =
             Iugu.list_withdraw_requests(status: "done", api_token: @subaccount_token)

    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"errors" => "not found"})
    end)

    assert {:error, %Error{kind: :not_found}} =
             Iugu.get_withdraw_request("MISSING", api_token: @subaccount_token)
  end

  test "master reconciles every subaccount's withdraws by update window, reading the decimal amounts in cents, and streams all pages" do
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/withdraw_conciliations"
      # The master's own token: the route returns the subaccounts' requests.
      assert_basic(conn, "iugu-test-token")
      assert_unsigned(conn)

      assert conn.query_params == %{
               "status" => "accepted",
               "from" => "2026-09-01T00:00:00-03:00",
               "to" => "2026-09-02T00:00:00-03:00",
               "limit" => "100"
             }

      Req.Test.json(conn, %{
        "total_items" => 109,
        "withdraw_requests" => [
          %{
            "id" => "2222222222222222222222222",
            "created_at" => "2024-08-15T10:40:51-03:00",
            "updated_at" => "2024-08-15T10:40:51-03:00",
            "amount" => "4500.0",
            "status" => "accepted",
            "feedback" => nil,
            "account_id" => "1111111111111111111",
            "custom_variables" => [%{"name" => "EmpresaiuguRequestId", "value" => "222dff87"}]
          }
        ]
      })
    end)

    assert {:ok, page} =
             Iugu.withdraw_conciliation(
               status: "accepted",
               from: ~U[2026-09-01 03:00:00Z],
               to: "2026-09-02T00:00:00-03:00",
               limit: 500
             )

    # "4500.0" here is reais, not the "R$ 4.500,00" of the other routes.
    assert [
             %{
               id: "2222222222222222222222222",
               status: "accepted",
               amount_cents: 450_000,
               account_id: "1111111111111111111",
               custom_variables: [%{"name" => "EmpresaiuguRequestId", "value" => "222dff87"}]
             }
           ] = page.withdraw_requests

    assert page.page_info == %{start: 0, limit: 100, total_items: 109}

    # An amount in a shape nobody documented is nil, never zero.
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.query_string == ""

      Req.Test.json(conn, %{
        "total_items" => 1,
        "withdraw_requests" => [%{"id" => "X", "status" => "pending", "amount" => 4500.0}]
      })
    end)

    assert {:ok, %{withdraw_requests: [%{id: "X", amount_cents: nil}]}} =
             Iugu.withdraw_conciliation()

    # The conciliation filter takes only the four statuses of its own list.
    assert {:error, %Error{kind: :validation, status: nil, path: "/v1/withdraw_conciliations"}} =
             Iugu.withdraw_conciliation(status: "inconsistent")

    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"errors" => %{"date" => ["Formato de data inválido para $start_date"]}})
    end)

    assert {:error, %Error{kind: :validation, status: 400, fields: %{"date" => [_message]}}} =
             Iugu.withdraw_conciliation(from: "ontem")

    # The stream walks the pages and stops on the short one, never trusting
    # total_items.
    Req.Test.expect(Iugu.Client, 2, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params do
        %{"start" => "0", "limit" => "2", "status" => "rejected"} ->
          Req.Test.json(conn, %{
            "total_items" => 999,
            "withdraw_requests" => [
              %{"id" => "1", "amount" => "1.0"},
              %{"id" => "2", "amount" => "2.5"}
            ]
          })

        %{"start" => "2", "limit" => "2", "status" => "rejected"} ->
          Req.Test.json(conn, %{
            "total_items" => 999,
            "withdraw_requests" => [%{"id" => "3", "amount" => "3.0"}]
          })
      end
    end)

    assert [{"1", 100}, {"2", 250}, {"3", 300}] =
             Iugu.stream_withdraw_conciliation(limit: 2, status: "rejected")
             |> Enum.map(&{&1.id, &1.amount_cents})

    assert "reprocessing" in Iugu.withdraw_request_statuses()

    assert Iugu.withdraw_conciliation_statuses() == [
             "pending",
             "processing",
             "accepted",
             "rejected"
           ]
  end
end
