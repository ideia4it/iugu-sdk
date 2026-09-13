defmodule Iugu.FinancialStatementTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  doctest Iugu.FinancialStatement

  setup {Req.Test, :verify_on_exit!}

  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"

  test "reads a subaccount's financial statement for a month in cents, finds the transfer entry, pages through it, and refuses an impossible month locally" do
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/accounts/financial"
      assert_basic(conn, @subaccount_token)
      assert_unsigned(conn)

      assert conn.query_params == %{
               "year" => "2024",
               "month" => "4",
               "limit" => "100",
               "hl" => "pt-BR"
             }

      Req.Test.json(conn, %{
        "transactions" => [
          %{
            "amount" => "R$ 1,00",
            "type" => "credit",
            "description" => "Pagamento recebido: Fatura #4C6A54F52FF04A969A9170ABA3C9C710",
            "entry_date" => "2024-04-08",
            "reference" => "4C6A54F52FF04A969A9170ABA3C9C710",
            "reference_type" => "Invoice",
            "account_id" => "27016E1AD888499A98994E781B6C3762",
            "transaction_type" => "misc",
            "invoice_email" => "js@email.com",
            "customer_name" => nil,
            "amount_cents" => "100.0",
            "balance" => "R$ 2,61",
            "balance_cents" => "261.0",
            "customer_ref" => "js@email.com",
            "payer_name" => nil
          },
          %{
            "amount" => "R$ -1,00",
            "type" => "debit",
            "description" => "Transferencia de Conta#27016e1a para Conta#0d16c52d",
            "entry_date" => "2024-04-10",
            "reference" => "94320E0695DE40FF919D82A0A17D012C",
            "reference_type" => "Transfer",
            "account_id" => nil,
            "transaction_type" => "misc",
            "amount_cents" => "-100.0",
            "balance" => "R$ 1,60",
            "balance_cents" => "160.0"
          }
        ],
        "initial_balance" => %{
          "amount" => "R$ 1,61",
          "amount_cents" => "161.0",
          "entry_date" => "2024-03-31"
        },
        "initial_date" => "2024-03-31T00:00:00-03:00",
        "final_date" => "2024-04-30T13:12:04-03:00",
        "transactions_total" => 4
      })
    end)

    assert {:ok, statement} =
             Iugu.financial_statement(
               year: 2024,
               month: "4",
               limit: 100,
               locale: "pt-BR",
               api_token: @subaccount_token
             )

    assert %{
             initial_balance_cents: 161,
             initial_balance_date: "2024-03-31",
             initial_date: "2024-03-31T00:00:00-03:00",
             final_date: "2024-04-30T13:12:04-03:00",
             transactions_total: 4,
             page_info: %{start: 0, limit: 100, total_items: nil}
           } = statement

    assert [
             %{
               type: "credit",
               amount_cents: 100,
               balance_cents: 261,
               entry_date: "2024-04-08",
               reference_type: "Invoice",
               invoice_email: "js@email.com",
               customer_ref: "js@email.com"
             },
             %{
               type: "debit",
               amount_cents: -100,
               balance_cents: 160,
               reference: "94320E0695DE40FF919D82A0A17D012C",
               reference_type: "Transfer",
               account_id: nil
             } = transfer_entry
           ] = statement.transactions

    assert transfer_entry.body["description"] =~ "Transferencia"

    # Without the cents field the formatted amount is read; an unreadable
    # one is nil, never zero.
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.query_string == ""

      Req.Test.json(conn, %{
        "transactions" => [
          %{"type" => "credit", "amount" => "R$ 1.234,56", "balance" => "R$ 1.234,56"},
          %{"type" => "debit", "amount" => -12.5, "balance" => "1234.56"}
        ],
        "initial_balance" => nil,
        "transactions_total" => "2"
      })
    end)

    assert {:ok,
            %{
              initial_balance_cents: nil,
              initial_balance_date: nil,
              transactions_total: 2,
              transactions: [
                %{amount_cents: 123_456, balance_cents: 123_456},
                %{amount_cents: nil, balance_cents: 123_456}
              ]
            }} = Iugu.financial_statement(api_token: @subaccount_token)

    # Each of these is a 400 from Iugu ("mon out of range", "mday out of
    # range"). No stub is standing, so the refusal is proven to skip the
    # network.
    refused = [
      {[month: 13], ~r/month/},
      {[month: "0"], ~r/month/},
      {[day: 32], ~r/day/},
      {[locale: "es"], ~r/locale/}
    ]

    for {opts, expected_message} <- refused do
      assert {:error,
              %Error{
                kind: :validation,
                status: nil,
                path: "/v1/accounts/financial",
                messages: [message]
              }} =
               Iugu.financial_statement(opts ++ [api_token: @subaccount_token])

      assert message =~ expected_message
    end

    # The stream pages with the same filters, clamps the limit to 1.000 and
    # stops on the short page.
    Req.Test.expect(Iugu.Client, 2, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["year"] == "2024"

      case conn.query_params do
        %{"start" => "0", "limit" => "1000"} ->
          Req.Test.json(conn, %{
            "transactions" => for(index <- 1..1000, do: %{"amount_cents" => "#{index}.0"}),
            "transactions_total" => 1001
          })

        %{"start" => "1000", "limit" => "1000"} ->
          Req.Test.json(conn, %{
            "transactions" => [%{"amount_cents" => "1001.0"}],
            "transactions_total" => 1001
          })
      end
    end)

    entries =
      Iugu.stream_financial_statement(year: 2024, limit: 5_000, api_token: @subaccount_token)
      |> Enum.to_list()

    assert length(entries) == 1001
    assert List.last(entries).amount_cents == 1001

    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"errors" => "Unauthorized"})
    end)

    assert {:error, %Error{kind: :unauthorized}} =
             Iugu.financial_statement(api_token: "TEST-TOKEN")
  end

  test "reads the invoice statement of a month, filtered by status, with the BRL strings in cents" do
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/accounts/invoices"
      assert_basic(conn, @subaccount_token)
      assert conn.query_params == %{"year" => "2024", "month" => "8", "status" => "pending"}

      Req.Test.json(conn, [
        %{
          "id" => "111D480C111147B08D0603548A078B40",
          "created_at" => "2024-08-01T14:45:11-03:00",
          "due_date" => "2024-08-18",
          "occurrence_date" => nil,
          "paid_at" => nil,
          "refunded_at" => nil,
          "pending_value" => "40.00 BRL",
          "paid_value" => "0.00 BRL",
          "taxes_paid" => "0.00 BRL",
          "payment_method" => nil,
          "installments" => nil,
          "customer_id" => nil,
          "customer_email" => "teste.teste@iugu.com",
          "customer_name" => nil,
          "subscription_id" => nil,
          "receivable_date" => nil,
          "receivable_reference" => nil,
          "receivable_total" => nil,
          "commission" => "1.20 BRL",
          "status" => "pending"
        }
      ])
    end)

    assert {:ok, [line]} =
             Iugu.invoices_statement(
               year: 2024,
               month: 8,
               status: "pending",
               api_token: @subaccount_token
             )

    assert %{
             id: "111D480C111147B08D0603548A078B40",
             status: "pending",
             due_date: "2024-08-18",
             customer_email: "teste.teste@iugu.com",
             installments: nil,
             pending_value_cents: 4_000,
             paid_value_cents: 0,
             taxes_paid_cents: 0,
             commission_cents: 120,
             receivable_total_cents: nil
           } = line

    assert line.body["occurrence_date"] == nil

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.query_string == ""

      Req.Test.json(conn, [])
    end)

    assert {:ok, []} = Iugu.invoices_statement(api_token: @subaccount_token)

    assert {:error, %Error{kind: :validation, status: nil, path: "/v1/accounts/invoices"}} =
             Iugu.invoices_statement(status: "done", api_token: @subaccount_token)

    assert "in_protest" in Iugu.statement_invoice_statuses()
  end

  test "reads the consolidated statement from a day to the end of the month, the settled amounts of a past day, and the consolidated receivables" do
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/accounts/consolidated_statements"
      assert_basic(conn, @subaccount_token)
      assert conn.query_params == %{"year" => "2024", "month" => "6", "day" => "7"}

      Req.Test.json(conn, %{
        "consolidated_statements" => [
          %{
            "id" => 974_098_447,
            "account_id" => "QND6TZC2KXT5MN9I9IR44R3N3J94JBR5",
            "movement_type" => "start_balance",
            "entry_date" => "2024-06-25",
            "total_amount_cents" => nil,
            "entries_count" => 1,
            "entry_order" => 0,
            "total_amount" => "2.59"
          },
          %{
            "id" => 974_098_448,
            "movement_type" => "withdraw",
            "entry_date" => "2024-06-25",
            "total_amount_cents" => -5000,
            "entries_count" => 1,
            "entry_order" => 10,
            "total_amount" => "-50.0"
          }
        ]
      })
    end)

    assert {:ok, rows} =
             Iugu.consolidated_statement(~D[2024-06-07], api_token: @subaccount_token)

    # The cents field wins when present; the reais string fills in when null.
    assert [
             %{
               id: 974_098_447,
               movement_type: "start_balance",
               entry_date: "2024-06-25",
               total_amount_cents: 259,
               entries_count: 1,
               entry_order: 0
             },
             %{movement_type: "withdraw", total_amount_cents: -5000, entry_order: 10}
           ] = rows

    assert Iugu.movement_type_description("start_balance") == "Saldo Inicial"
    assert "receivable_unit_settlement" in Iugu.movement_types()

    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.request_path == "/v1/accounts/financial/settled"
      assert conn.query_params == %{"date" => "2024-08-16"}

      Req.Test.json(conn, %{
        "date" => "2024-08-16",
        "total_transactions_amount" => 0,
        "total_payments_amount" => 112_344,
        "transactions" => [],
        "payments" => %{
          "self" => [%{"amount_cents" => 0, "transaction_code" => "MCC", "payment_date" => nil}],
          "external" => [
            %{
              "amount_cents" => 12_345,
              "transaction_code" => "VCC",
              "payment_date" => nil,
              "destination_document" => "12300078000000",
              "destination_branch" => "1234",
              "destination_account" => "123456"
            }
          ]
        }
      })
    end)

    assert {:ok, settled} =
             Iugu.settled_statement(~D[2024-08-16], api_token: @subaccount_token)

    assert %{
             date: "2024-08-16",
             total_transactions_amount_cents: 0,
             total_payments_amount_cents: 112_344,
             transactions: [],
             payments: %{
               self: [%{"transaction_code" => "MCC"}],
               external: [%{"amount_cents" => 12_345, "destination_branch" => "1234"} = external]
             }
           } = settled

    assert Iugu.card_brand(external["transaction_code"]) == "visa"

    # Iugu only consolidates up to yesterday; today is refused here.
    assert {:error,
            %Error{kind: :validation, status: nil, path: "/v1/accounts/financial/settled"}} =
             Iugu.settled_statement(Date.utc_today(), api_token: @subaccount_token)

    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.request_path == "/v1/accounts/consolidated_receivables"

      assert conn.query_params == %{
               "scheduled_date_from" => "2024-07-01",
               "scheduled_date_to" => "2024-07-31"
             }

      Req.Test.json(conn, %{
        "consolidated_receivables" => [
          %{
            "id" => 111_111_111,
            "entry_date" => "2024-08-16",
            "scheduled_date" => "2024-07-06",
            "canceled_amount_cents" => 400,
            "total_amount_cents" => 400,
            "total_fee_cents" => 58,
            "transaction_code" => "VCC",
            "advance_fee_today" => "-0.0474",
            "amount_availableble_for_advance_today_cents" => 1_500
          }
        ]
      })
    end)

    assert {:ok, [receivable]} =
             Iugu.consolidated_receivables(
               scheduled_date_from: ~D[2024-07-01],
               scheduled_date_to: ~D[2024-07-31],
               api_token: @subaccount_token
             )

    assert receivable["total_amount_cents"] == 400
    assert receivable["scheduled_date"] == "2024-07-06"
    # The misspelled key stays, and the readable copy sits next to it.
    assert receivable["amount_availableble_for_advance_today_cents"] == 1_500
    assert receivable["amount_available_for_advance_today_cents"] == 1_500

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.query_string == ""

      Req.Test.json(conn, %{"consolidated_receivables" => []})
    end)

    assert {:ok, []} = Iugu.consolidated_receivables(api_token: @subaccount_token)

    # The documented failure of these reports is a bare 400.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{})
    end)

    assert {:error, %Error{kind: :validation, status: 400, messages: []}} =
             Iugu.consolidated_statement(~D[2024-06-07], api_token: @subaccount_token)
  end
end
