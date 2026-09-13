defmodule Iugu.SplitTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error
  alias Iugu.Split

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  doctest Split

  @account_token "SUBACCOUNT-LIVE-TOKEN"

  test "builds every documented rule shape, converts it to the API keys and reads it back from every payload Iugu writes" do
    # The eight recipes from the docs, one struct each, and the exact keys
    # they send: nothing nil, integers where the recipe shows "499".
    assert Split.to_params([Split.fixed("ACC", 499)]) == [
             %{"recipient_account_id" => "ACC", "cents" => 499}
           ]

    assert Split.to_params([Split.percent("ACC", 4)]) == [
             %{"recipient_account_id" => "ACC", "percent" => 4}
           ]

    assert Split.to_params([Split.aggregated("ACC", 499, 4)]) == [
             %{
               "recipient_account_id" => "ACC",
               "cents" => 499,
               "percent" => 4,
               "permit_aggregated" => true
             }
           ]

    assert Split.to_params([
             Split.new(%{
               "recipient_account_id" => "ACC",
               "permit_aggregated" => true,
               "pix_cents" => 499,
               "pix_percent" => 4
             })
           ]) == [
             %{
               "recipient_account_id" => "ACC",
               "permit_aggregated" => true,
               "pix_cents" => 499,
               "pix_percent" => 4
             }
           ]

    assert Split.to_params([
             Split.new(
               recipient_account_id: "ACC",
               credit_card_1x_cents: 20,
               credit_card_12x_percent: 1.5
             )
           ]) == [
             %{
               "recipient_account_id" => "ACC",
               "credit_card_1x_cents" => 20,
               "credit_card_12x_percent" => 1.5
             }
           ]

    assert %Split{installments: %{1 => %{cents: 20, percent: 2}}} =
             Split.new(
               recipient_account_id: "ACC",
               credit_card_1x_cents: 20,
               credit_card_1x_percent: 2
             )

    # A typo in a field name is a programming error, not something to send
    # to Iugu and read back as a 422.
    assert_raise ArgumentError, ~r/credit_card_19x_cents/, fn ->
      Split.new(recipient_account_id: "ACC", credit_card_19x_cents: 1)
    end

    assert_raise ArgumentError, ~r/recipient_account_id/, fn -> Split.new(cents: 10) end

    # Reading back: the account response writes 0 for the generic fields it
    # did not use and the rule id as "d"; the current-split response only
    # writes the fields that are set; the invoice writes the full object with
    # nulls and 13x..18x installments.
    account_payload = %{
      "splits" => [
        %{
          "d" => "937D2E09",
          "split_id" => "F81629A2",
          "recipient_account_id" => "SUB",
          "cents" => 0,
          "percent" => 0,
          "pix_cents" => "109",
          "permit_aggregated" => false,
          "credit_card_3x_percent" => "1.5"
        }
      ]
    }

    assert [
             %Split{
               id: "937D2E09",
               split_id: "F81629A2",
               recipient_account_id: "SUB",
               cents: nil,
               percent: nil,
               pix_cents: 109,
               permit_aggregated: false,
               installments: %{3 => %{cents: nil, percent: 1.5}}
             }
           ] = Split.from_payload(account_payload)

    current_payload = %{
      "id" => "0F143A08",
      "splittable_id" => "E255E580",
      "splittable_type" => "Account",
      "split_rules" => [
        %{"recipient_account_id" => "A", "cents" => 1000},
        %{"recipient_account_id" => "B", "percent" => 1.5},
        %{"cents" => 5}
      ]
    }

    assert [
             %Split{recipient_account_id: "A", cents: 1000, percent: nil},
             %Split{recipient_account_id: "B", cents: nil, percent: 1.5}
           ] = Split.from_payload(current_payload)

    invoice_payload = %{
      "split_rules" => [
        %{
          "id" => "AB1B22F3",
          "split_id" => "3270D0BA",
          "recipient_account_id" => "E638DCED",
          "cents" => 10,
          "percent" => 1,
          "credit_card_cents" => nil,
          "pix_percent" => nil,
          "permit_aggregated" => true,
          "credit_card_1x_cents" => nil,
          "credit_card_18x_cents" => 7
        }
      ]
    }

    assert [
             %Split{
               id: "AB1B22F3",
               recipient_account_id: "E638DCED",
               cents: 10,
               percent: 1,
               permit_aggregated: true,
               installments: %{18 => %{cents: 7, percent: nil}}
             }
           ] = Split.from_payload(invoice_payload)

    assert [%Split{recipient_account_id: "A", cents: 1000}] =
             Split.from_payload([%{"recipient_account_id" => "A", "cents" => 1000}])

    assert [] = Split.from_payload(%{"split_rules" => nil})
    assert [] = Split.from_payload(%{})

    # Round trip: what was read back is what gets sent again.
    assert Split.to_params(Split.from_payload(current_payload)) == [
             %{"recipient_account_id" => "A", "cents" => 1000},
             %{"recipient_account_id" => "B", "percent" => 1.5}
           ]
  end

  test "validates the rules the docs state before the call and estimates what the splits take from an invoice, by payment method and in the worst case" do
    splits = [Split.percent("A", 10), Split.fixed("B", 250)]

    assert :ok = Split.validate(splits)
    assert :ok = Split.validate(splits, 10_000)
    assert :ok = Split.validate(splits, 10_000, own_account_id: "MASTER")
    assert Split.total_cents(splits, 10_000) == 1_250

    # Percent first, then cents, on one aggregated rule; 1.5% of R$ 33,33 is
    # 49.995 cents and rounds up.
    assert Split.total_cents([Split.aggregated("A", 100, 1.5)], 3_333) == 150

    # Per-method amounts count only for that method; an unknown method, or an
    # unknown installment count on the card, means the worst case, which is
    # what the "never reach the total" rule must survive.
    mixed =
      Split.new(
        recipient_account_id: "A",
        cents: 100,
        pix_cents: 50,
        bank_slip_percent: 2,
        credit_card_percent: 3,
        credit_card_6x_cents: 400,
        permit_aggregated: true
      )

    assert Split.total_cents([mixed], 10_000, payment_method: "pix") == 150
    assert Split.total_cents([mixed], 10_000, payment_method: "bank_slip") == 300
    assert Split.total_cents([mixed], 10_000, payment_method: "credit_card") == 800

    assert Split.total_cents([mixed], 10_000, payment_method: "credit_card", installments: 6) ==
             800

    assert Split.total_cents([mixed], 10_000, payment_method: "credit_card", installments: 2) ==
             400

    assert Split.total_cents([mixed], 10_000) == 800

    assert_raise ArgumentError, ~r/forma de pagamento/, fn ->
      Split.total_cents([mixed], 10_000, payment_method: "debit_card")
    end

    assert Split.payment_methods() == ["credit_card", "bank_slip", "pix"]

    # Each of these is either a 422 from Iugu or, worse, a split that is
    # silently ignored at payment time.
    refused = [
      {[%Split{recipient_account_id: ""}], 10_000, [], ~r/recipient_account_id/},
      {[%Split{recipient_account_id: "A"}], 10_000, [], ~r/centavos ou em percentual/},
      {[Split.fixed("A", 0)], 10_000, [], ~r/positivo/},
      {[Split.percent("A", -1)], 10_000, [], ~r/positivo/},
      {[%Split{recipient_account_id: "A", cents: 100, percent: 1}], 10_000, [],
       ~r/permit_aggregated/},
      {[Split.new(recipient_account_id: "A", pix_cents: 10, credit_card_percent: 1)], 10_000, [],
       ~r/permit_aggregated/},
      {[Split.fixed("MASTER", 100)], 10_000, [own_account_id: "MASTER"], ~r/conta criadora/},
      {[Split.fixed("A", 100), Split.percent("A", 1)], 10_000, [], ~r/uma vez só/},
      {[Split.percent("A", 60), Split.percent("B", 40)], nil, [], ~r/100%/},
      {[Split.percent("A", 100)], 10_000, [], ~r/100%/},
      {[Split.fixed("A", 6_000), Split.fixed("B", 4_000)], 10_000, [], ~r/abaixo do total/},
      {[Split.fixed("A", 10_001)], 10_000, [], ~r/abaixo do total/},
      {[Split.new(recipient_account_id: "A", credit_card_12x_cents: 10_000)], 10_000, [],
       ~r/abaixo do total/}
    ]

    for {splits, total, opts, expected_message} <- refused do
      assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
               Split.validate(splits, total, opts)

      assert message =~ expected_message
    end

    # Without a total the cents rule cannot be judged, so it passes; the
    # percent rule still applies.
    assert :ok = Split.validate([Split.fixed("A", 10_001)])
    assert :ok = Split.validate([Split.percent("A", 99.9)])
  end

  test "reads the account default split and replaces it with the account's own token, refusing locally what Iugu would reject" do
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/splits/current"
      assert_basic(conn, @account_token)
      assert_unsigned(conn)

      Req.Test.json(conn, %{
        "id" => "0F143A08D30C4A009E27CD8ED88601C3",
        "splittable_id" => "E255E580AB9B49B087F9FBA07CD0A1A3",
        "splittable_type" => "Account",
        "split_rules" => [
          %{"recipient_account_id" => "11DA8B16", "cents" => 1000},
          %{"recipient_account_id" => "0958D2AA", "percent" => 1.5}
        ]
      })
    end)

    assert {:ok,
            %{
              id: "0F143A08D30C4A009E27CD8ED88601C3",
              account_id: "E255E580AB9B49B087F9FBA07CD0A1A3",
              split_rules: [
                %Split{recipient_account_id: "11DA8B16", cents: 1000},
                %Split{recipient_account_id: "0958D2AA", percent: 1.5}
              ],
              body: %{"splittable_type" => "Account"}
            }} = Iugu.current_split(api_token: @account_token)

    # Replacing: the key is split_rules, not splits, and the whole list goes
    # every time because the new configuration overrides the old one.
    Req.Test.expect(Iugu.Client, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/v1/splits"
      assert_basic(conn, @account_token)
      assert_unsigned(conn)

      assert Jason.decode!(raw_body) == %{
               "split_rules" => [
                 %{"recipient_account_id" => "8DF741D7", "cents" => 100},
                 %{"recipient_account_id" => "SUBB", "percent" => 2.5}
               ]
             }

      Req.Test.json(conn, %{
        "id" => "4322DAFCE8574D058D83E2F8E29F1951",
        "splittable_id" => "27016E1AD888499A98994E781B6C3762",
        "splittable_type" => "Account",
        "split_rules" => [
          %{"id" => "9EFED8C0", "recipient_account_id" => "8DF741D7", "cents" => 100},
          %{"id" => "9EFED8C1", "recipient_account_id" => "SUBB", "percent" => 2.5}
        ]
      })
    end)

    assert {:ok,
            %{
              account_id: "27016E1AD888499A98994E781B6C3762",
              split_rules: [
                %Split{id: "9EFED8C0", cents: 100},
                %Split{id: "9EFED8C1", percent: 2.5}
              ]
            }} =
             Iugu.set_default_split([Split.fixed("8DF741D7", 100), Split.percent("SUBB", 2.5)],
               api_token: @account_token
             )

    # No stub standing: the refusal never reaches the network.
    assert {:error, %Error{kind: :validation, status: nil, messages: [message]}} =
             Iugu.set_default_split([Split.fixed("27016E1A", 100)],
               api_token: @account_token,
               own_account_id: "27016E1A"
             )

    assert message =~ "conta criadora"

    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{
        "errors" => %{"splits" => ["Conta do destinatário deve estar no mesmo contexto"]}
      })
    end)

    assert {:error,
            %Error{
              kind: :validation,
              status: 422,
              fields: %{"splits" => ["Conta do destinatário deve estar no mesmo contexto"]}
            }} = Iugu.set_default_split([Split.fixed("OUTSIDER", 100)], api_token: @account_token)
  end
end
