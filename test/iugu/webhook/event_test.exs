defmodule Iugu.Webhook.EventTest do
  use ExUnit.Case, async: true

  alias Iugu.Webhook.Event

  doctest Iugu.Webhook.Event

  test "reads a paid invoice the way Plug decodes the form body, types every field and builds the dedupe key" do
    # This is what Plug.Parsers.URLENCODED hands over for
    # event=invoice.status_changed&data[id]=...&data[status]=paid
    {:ok, event} =
      Event.parse(%{
        "event" => "invoice.status_changed",
        "data" => %{
          "id" => "1757E1D7FD5E410A9C563024250015BF",
          "account_id" => "70CA234077134ED0BF2E0E46B0EDC36F",
          "status" => "paid",
          "payment_method" => "iugu_pix",
          "paid_at" => "2022-03-21T11:07:36.667Z",
          "payer_cpf_cnpj" => "66535209008",
          "subscription_id" => "F4115E5E28AE4CCA941FCCCCCABE9A0A",
          "pix_end_to_end_id" => "c2403281-a401-496b-af0e-53b7e16ba207",
          "paid_cents" => "100",
          "order_id" => "N77579_31658163",
          "async_charged" => "true",
          "external_reference" => "N55548889"
        }
      })

    assert %Event{event: "invoice.status_changed", account_id: "70CA234077134ED0BF2E0E46B0EDC36F"} =
             event

    assert Event.invoice_event?(event)
    refute Event.kyc_event?(event)
    assert Event.invoice_id(event) == "1757E1D7FD5E410A9C563024250015BF"
    assert Event.object_id(event) == "1757E1D7FD5E410A9C563024250015BF"
    assert Event.subscription_id(event) == "F4115E5E28AE4CCA941FCCCCCABE9A0A"
    assert Event.status(event) == "paid"
    assert Event.paid?(event)
    assert Event.payment_method(event) == "iugu_pix"
    assert Event.paid_cents(event) == 100
    assert Event.paid_at(event) == ~U[2022-03-21 11:07:36.667Z]
    assert Event.payer_cpf_cnpj(event) == "66535209008"
    assert Event.pix_end_to_end_id(event) == "c2403281-a401-496b-af0e-53b7e16ba207"
    assert Event.order_id(event) == "N77579_31658163"
    assert Event.external_reference(event) == "N55548889"
    assert Event.boolean_field(event, "async_charged") == true

    assert Event.idempotency_key(event) ==
             "invoice.status_changed|1757E1D7FD5E410A9C563024250015BF|paid"

    # A manual or period resend replays the same payload byte for byte, so it
    # lands on the same key; the next status change gets a new one.
    {:ok, replayed} = Event.parse(event.payload)
    assert Event.idempotency_key(replayed) == Event.idempotency_key(event)

    {:ok, refunded} = Event.parse(put_in(event.payload, ["data", "status"], "refunded"))
    refute Event.idempotency_key(refunded) == Event.idempotency_key(event)
    refute Event.paid?(refunded)

    # Absent and empty values are nil, never zero or false: the logs show
    # data[async_charged]= arriving empty without meaning "no".
    {:ok, created} =
      Event.parse(%{
        "event" => "invoice.created",
        "data" => %{"id" => "X", "status" => "pending", "async_charged" => "", "paid_cents" => ""}
      })

    assert Event.boolean_field(created, "async_charged") == nil
    assert Event.paid_cents(created) == nil
    assert Event.paid_at(created) == nil
    assert Event.subscription_id(created) == nil
    assert created.account_id == nil
    refute Event.paid?(created)

    # partially_paid and authorized are not money in the account.
    for status <- ["partially_paid", "authorized", "externally_paid", "pending"] do
      {:ok, not_paid} =
        Event.parse(%{
          "event" => "invoice.status_changed",
          "data" => %{"id" => "X", "status" => status}
        })

      refute Event.paid?(not_paid)
    end
  end

  test "reads the KYC events: verification accepted then rejected, bank domicile and a document sent back" do
    {:ok, accepted} =
      Event.parse(%{
        "event" => "referrals.verification",
        "data" => %{
          "id" => "4857E1D7FD5E410A9C563024250015TC",
          "account_id" => "70CA234077134ED0BF2E0E46B0EDC36F",
          "status" => "accepted",
          "charge_limit_cents" => "5000"
        }
      })

    assert Event.kyc_event?(accepted)
    assert Event.verified?(accepted)
    assert accepted.account_id == "70CA234077134ED0BF2E0E46B0EDC36F"
    assert Event.object_id(accepted) == "4857E1D7FD5E410A9C563024250015TC"
    assert Event.charge_limit_cents(accepted) == 5_000
    assert Event.feedback(accepted) == nil
    # data[id] here is the verification, not an invoice.
    assert Event.invoice_id(accepted) == nil

    {:ok, rejected} =
      Event.parse(%{
        "event" => "referrals.verification",
        "data" => %{
          "id" => "4857E1D7FD5E410A9C563024250015TC",
          "account_id" => "70CA234077134ED0BF2E0E46B0EDC36F",
          "status" => "rejected",
          "feedback" => "CPF do responsável não confere com a Receita."
        }
      })

    refute Event.verified?(rejected)
    assert Event.status(rejected) == "rejected"
    assert Event.feedback(rejected) == "CPF do responsável não confere com a Receita."

    {:ok, bank} =
      Event.parse(%{
        "event" => "referrals.bank_verification",
        "data" => %{"id" => "B1", "account_id" => "ACC", "status" => "accepted"}
      })

    assert Event.kyc_event?(bank)
    # Only the account verification itself means the account is verified.
    refute Event.verified?(bank)
    assert Event.status(bank) == "accepted"

    # The document event has no id; the docs also misspell the document type.
    {:ok, document} =
      Event.parse(%{
        "event" => "referrals.document_status_change",
        "data" => %{
          "status" => "requested",
          "account_id" => "ACC",
          "document_type" => "additiconal_document_one",
          "reason" => "Documento ilegível."
        }
      })

    assert Event.document_type(document) == "additional_document_one"
    assert Event.feedback(document) == "Documento ilegível."
    assert Event.object_id(document) == nil

    assert Event.idempotency_key(document) =~
             ~r/\Areferrals\.document_status_change\|hash-\d+\|requested\z/
  end

  test "reads the ids of the other families whether the keys came under data or bare, with the name in event or data[event]" do
    # Pix/TED out documents its keys without the data[] prefix.
    {:ok, transfer_request} =
      Event.parse(%{
        "event" => "transfer_request.done",
        "transfer_request_id" => "B213D7E3211F4FA5A123BCDE8F1G4567",
        "transfer_status" => "done",
        "amount_cents" => "10000",
        "sender_account_id" => "AA5B6DC7E783FA1A963CBCA382105F4C",
        "done_at" => "2024-10-23T18:13:01.453Z"
      })

    assert Event.transfer_event?(transfer_request)
    assert Event.object_id(transfer_request) == "B213D7E3211F4FA5A123BCDE8F1G4567"
    assert Event.status(transfer_request) == "done"
    assert Event.amount_cents(transfer_request) == 10_000
    assert Event.datetime_field(transfer_request, "done_at") == ~U[2024-10-23 18:13:01.453Z]

    # Transfers between accounts document the name under data[event].
    {:ok, credited} =
      Event.parse(%{
        "data" => %{
          "event" => "transfer.credited",
          "transfer_id" => "EFGH5678IJKL9012MNOP3456ABCD1234",
          "receiver_account_id" => "RCV",
          "transfer_type" => "debit_transfer",
          "amount_cents" => "2000"
        }
      })

    assert credited.event == "transfer.credited"
    assert Event.transfer_event?(credited)
    assert Event.object_id(credited) == "EFGH5678IJKL9012MNOP3456ABCD1234"
    assert Event.amount_cents(credited) == 2_000
    refute Map.has_key?(credited.data, "event")

    {:ok, withdraw} =
      Event.parse(%{
        "event" => "withdraw_request.status_changed",
        "data" => %{
          "withdraw_request_id" => "F9EAB5678DC43ABC89123JKL45678QW",
          "account_id" => "1234ABC5678XYZ123ABCD0987654321",
          "status" => "rejected",
          "agreement_effect" => "false",
          "rejected_after_accepted" => "true",
          "feedback" => "CH11"
        }
      })

    assert Event.withdraw_event?(withdraw)
    assert Event.object_id(withdraw) == "F9EAB5678DC43ABC89123JKL45678QW"
    assert Event.boolean_field(withdraw, "agreement_effect") == false
    assert Event.boolean_field(withdraw, "rejected_after_accepted") == true
    assert Event.feedback(withdraw) == "CH11"

    {:ok, subscription} =
      Event.parse(%{
        "event" => "subscription.renewed",
        "data" => %{
          "id" => "SUB",
          "account_id" => "ACC",
          "customer_email" => "ana@loja.example",
          "expires_at" => "2025-10-08"
        }
      })

    assert Event.subscription_event?(subscription)
    assert Event.subscription_id(subscription) == "SUB"
    assert Event.invoice_id(subscription) == nil
    assert Event.date_field(subscription, "expires_at") == ~D[2025-10-08]
    assert Event.date_field(subscription, "customer_email") == nil

    {:ok, deposit} =
      Event.parse(%{
        "event" => "deposit.pix_status_changed",
        "deposit_id" => "B123F45G6HI789JKL012MNO345P678QR",
        "status" => "refunded",
        "account_id" => "67890ABCDEF1234567890GHIJKLMN456",
        "amount_cents" => "1000"
      })

    assert Event.object_id(deposit) == "B123F45G6HI789JKL012MNO345P678QR"
    assert deposit.account_id == "67890ABCDEF1234567890GHIJKLMN456"

    # When both shapes come at once, the nested data wins over the bare key.
    {:ok, both} =
      Event.parse(%{
        "event" => "payment_request.created",
        "payment_request_id" => "OUTER",
        "data" => %{"payment_request_id" => "INNER"}
      })

    assert Event.object_id(both) == "INNER"
  end

  test "decodes the raw form body, and rejects a payload without a known event name instead of atomizing it" do
    raw =
      "event=invoice.status_changed&data%5Bid%5D=ABC&data%5Bstatus%5D=paid&data%5Bpaid_cents%5D=250"

    assert {:ok, event} = Event.decode_form(raw)
    assert Event.invoice_id(event) == "ABC"
    assert Event.paid_cents(event) == 250

    # Never String.to_atom on a value coming off the network.
    assert {:error, :unsupported_event} = Event.parse(%{"event" => "invoice.brand_new"})
    assert {:error, :unsupported_event} = Event.parse(%{"event" => "all"})
    assert {:error, :unsupported_event} = Event.parse(%{"event" => nil, "data" => %{}})
    assert {:error, :unsupported_event} = Event.parse(%{"data" => %{"id" => "X"}})
    assert {:error, :unsupported_event} = Event.parse(%{})
    assert {:error, :unsupported_event} = Event.parse("not a map")
    assert {:error, :unsupported_event} = Event.decode_form("garbage=1")

    # A data key that is not a map is dropped rather than crashing the parse.
    assert {:ok, %Event{event: "invoice.created", data: %{}}} =
             Event.parse(%{"event" => "invoice.created", "data" => "x"})
  end

  test "authorizes a delivery only against the configured secret, raw or wrapped as Basic, in either header shape" do
    # The configured value comes from config/test.exs.
    assert Event.authorized?("iugu-test-webhook-authorization")
    assert Event.authorized?(["iugu-test-webhook-authorization"])
    assert Event.authorized?("Basic " <> Base.encode64("iugu-test-webhook-authorization"))
    refute Event.authorized?("Basic " <> Base.encode64("iugu-test-webhook-authorization:"))
    refute Event.authorized?("wrong")
    refute Event.authorized?(nil)
    refute Event.authorized?([])
    refute Event.authorized?(["a", "b"])

    # An explicit expected value overrides the config; an empty or missing
    # secret never authorizes anything, so a misconfigured environment fails
    # closed instead of accepting every delivery.
    assert Event.authorized?("other", "other")
    refute Event.authorized?("iugu-test-webhook-authorization", "other")
    refute Event.authorized?("", "")
    refute Event.authorized?("x", nil)
  end
end
