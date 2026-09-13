defmodule Iugu.WebhookTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error
  alias Iugu.Webhook.Event

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  @url "https://app.example.com/v1/webhooks/iugu"
  @subaccount_token "SUBACCOUNT-LIVE-TOKEN"

  test "registers a trigger on a subaccount with basic auth, reads it back, changes its secret, lists the account and deletes it" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/web_hooks"
      assert_basic(conn, @subaccount_token)
      assert conn.query_string == ""
      assert Plug.Conn.get_req_header(conn, "request-time") == []

      assert body == %{
               "event" => "invoice.status_changed",
               "url" => @url,
               "authorization" => "s3cr3t"
             }

      Req.Test.json(conn, %{
        "id" => "C79D36E7B6E74150B28F6CCA2EAC7707",
        "url" => @url,
        "authorization" => "s3cr3t",
        "event" => "invoice.status_changed",
        "active" => true
      })
    end)

    assert {:ok, trigger} =
             Iugu.create_webhook(
               %{event: "invoice.status_changed", url: @url, authorization: "s3cr3t"},
               api_token: @subaccount_token
             )

    assert %{
             id: "C79D36E7B6E74150B28F6CCA2EAC7707",
             url: @url,
             event: "invoice.status_changed",
             authorization: "s3cr3t",
             active: true
           } = trigger

    # Fields not given are omitted, never sent as null; active only goes out
    # when the caller asks for it.
    expect_request(fn conn, body ->
      assert body == %{"event" => "all", "url" => @url, "active" => false}

      Req.Test.json(conn, %{"id" => "ALL", "event" => "all", "url" => @url, "active" => false})
    end)

    assert {:ok, %{id: "ALL", active: false}} =
             Iugu.create_webhook(%{"event" => "all", "url" => @url, "active" => false})

    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/web_hooks/C79D36E7B6E74150B28F6CCA2EAC7707"

      Req.Test.json(conn, %{
        "id" => "C79D36E7B6E74150B28F6CCA2EAC7707",
        "url" => @url,
        "authorization" => nil,
        "event" => "invoice.status_changed",
        "active" => true
      })
    end)

    assert {:ok, %{id: "C79D36E7B6E74150B28F6CCA2EAC7707", authorization: nil}} =
             Iugu.get_webhook("C79D36E7B6E74150B28F6CCA2EAC7707")

    # A partial update carries only what changes.
    expect_request(fn conn, body ->
      assert conn.method == "PUT"
      assert conn.request_path == "/v1/web_hooks/C79D36E7B6E74150B28F6CCA2EAC7707"
      assert body == %{"authorization" => "n3w"}

      Req.Test.json(conn, %{
        "id" => "C79D36E7B6E74150B28F6CCA2EAC7707",
        "url" => @url,
        "authorization" => "n3w",
        "event" => "invoice.status_changed",
        "active" => true
      })
    end)

    assert {:ok, %{authorization: "n3w"}} =
             Iugu.update_webhook("C79D36E7B6E74150B28F6CCA2EAC7707", %{authorization: "n3w"})

    # The listing has no filter on the API side: url and event are local, so a
    # sync never touches another integration's triggers.
    Req.Test.expect(Iugu.Client, 2, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/web_hooks"
      assert conn.query_string == ""

      Req.Test.json(conn, [
        %{"id" => "A", "url" => @url, "event" => "invoice.status_changed", "active" => true},
        %{"id" => "B", "url" => "https://outro.example/hook", "event" => "all", "active" => true},
        %{"id" => "C", "url" => @url, "event" => "referrals.verification", "active" => true}
      ])
    end)

    assert {:ok, [%{id: "A"}, %{id: "B"}, %{id: "C"}]} = Iugu.list_webhooks()

    assert {:ok, [%{id: "A"}]} = Iugu.list_webhooks(url: @url, event: "invoice.status_changed")

    # The reference shows a lone object where the text says list; one trigger
    # arriving bare must not read as none.
    Req.Test.expect(Iugu.Client, fn conn ->
      Req.Test.json(conn, %{"id" => "ONLY", "url" => @url, "event" => "all", "active" => true})
    end)

    assert {:ok, [%{id: "ONLY", event: "all"}]} = Iugu.list_webhooks()

    # Deleting answers with the object, not a 204.
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/web_hooks/N37ZZ9X2GBS59MT37SPGOGDDBTX4HGZ4"

      Req.Test.json(conn, %{
        "id" => "N37ZZ9X2GBS59MT37SPGOGDDBTX4HGZ4",
        "url" => @url,
        "authorization" => nil,
        "event" => "invoice.created",
        "active" => true
      })
    end)

    assert {:ok, %{id: "N37ZZ9X2GBS59MT37SPGOGDDBTX4HGZ4", event: "invoice.created"}} =
             Iugu.delete_webhook("N37ZZ9X2GBS59MT37SPGOGDDBTX4HGZ4")
  end

  test "refuses locally what Iugu would answer 422 to, and maps the 422 it does answer" do
    # Iugu demands https; the check happens before spending the call.
    assert {:error, %Error{kind: :validation, status: nil} = error} =
             Iugu.create_webhook(%{event: "invoice.created", url: "http://app.example.com/hook"})

    assert error.messages == ["url deve ser uma URL válida começando com https://."]

    assert {:error, %Error{kind: :validation, status: nil}} =
             Iugu.create_webhook(%{event: "invoice.created", url: "https://"})

    assert {:error, %Error{kind: :validation, messages: ["event é obrigatório."]}} =
             Iugu.create_webhook(%{url: @url})

    assert {:error, %Error{kind: :validation, messages: ["url é obrigatório."]}} =
             Iugu.create_webhook(%{event: "invoice.created", url: ""})

    assert {:error, %Error{kind: :validation, status: nil}} =
             Iugu.update_webhook("ID", %{url: "ftp://app.example.com"})

    assert_raise ArgumentError, ~r/campo desconhecido/, fn ->
      Iugu.create_webhook(%{event: "invoice.created", url: @url, name: "x"})
    end

    # The event list is per account, so membership is Iugu's call: the 422
    # comes back by field.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"errors" => %{"event" => ["is invalid."]}})
    end)

    assert {:error, %Error{kind: :validation, status: 422} = error} =
             Iugu.create_webhook(%{event: "invoice.whatever", url: @url})

    assert error.fields == %{"event" => ["is invalid."]}

    # The twenty-first trigger is refused with the account error.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(422)
      |> Req.Test.json(%{"errors" => %{"account" => ["não pode ter mais de 30 gatilhos"]}})
    end)

    assert {:error, %Error{messages: ["account: não pode ter mais de 30 gatilhos"]}} =
             Iugu.create_webhook(%{event: "invoice.created", url: @url})
  end

  test "asks the account which events it can listen to and knows the documented catalogue by group" do
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/web_hooks/supported_events"

      Req.Test.json(conn, ["all", "invoice.created", "invoice.status_changed", nil, 1])
    end)

    assert {:ok, ["all", "invoice.created", "invoice.status_changed"]} =
             Iugu.list_webhook_events()

    events = Iugu.webhook_events()

    assert "all" in events
    assert "invoice.status_changed" in events
    assert "referrals.document_status_change" in events
    assert "transfer.credited" in events
    assert events == Enum.uniq(events)

    # Every grouped helper is a subset of the catalogue, and the groups do not
    # overlap, so a sync built from them never registers an event twice.
    groups = [
      Iugu.invoice_webhook_events(),
      Iugu.subscription_webhook_events(),
      Iugu.kyc_webhook_events(),
      Iugu.withdraw_webhook_events(),
      Iugu.transfer_webhook_events(),
      Iugu.deposit_webhook_events()
    ]

    for group <- groups, event <- group, do: assert(event in events)

    grouped = List.flatten(groups)
    assert grouped == Enum.uniq(grouped)

    assert "referrals.verification" in Iugu.kyc_webhook_events()
    assert "withdraw_request.status_changed" in Iugu.withdraw_webhook_events()
    assert "transfer_request.done" in Iugu.transfer_webhook_events()
    assert "transfer.debited" in Iugu.transfer_webhook_events()
    assert Iugu.webhook_outbound_ip() == "98.82.243.132"
  end

  test "resends a period as a query-string GET without retry, refuses a window wider than three days and reads the message" do
    test_pid = self()

    Req.Test.expect(Iugu.Client, fn conn ->
      send(test_pid, :iugu_attempt)
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/web_hooks/resend"

      assert conn.query_params == %{
               "initial_date" => "2026-08-01",
               "final_date" => "2026-08-03",
               "event" => "invoice.status_changed"
             }

      Req.Test.json(conn, %{
        "message" =>
          "Os gatilhos do período foram enviados para procesasamento, aguarde alguns instantes"
      })
    end)

    assert {:ok, %{message: "Os gatilhos do período foram enviados" <> _rest}} =
             Iugu.resend_webhooks_by_period(~D[2026-08-01], ~D[2026-08-03],
               event: "invoice.status_changed"
             )

    assert_received :iugu_attempt

    # Four days is over the limit; nothing is sent.
    assert {:error, %Error{kind: :validation, status: nil}} =
             Iugu.resend_webhooks_by_period(~D[2026-08-01], ~D[2026-08-05])

    assert {:error, %Error{kind: :validation, status: nil}} =
             Iugu.resend_webhooks_by_period(~D[2026-08-05], ~D[2026-08-01])

    # A GET with a side effect: a timeout is not retried, or the period would
    # be replayed twice.
    Req.Test.expect(Iugu.Client, fn conn ->
      send(test_pid, :iugu_attempt)
      Req.Test.transport_error(conn, :timeout)
    end)

    assert {:error, %Error{kind: :transport}} =
             Iugu.resend_webhooks_by_period(~D[2026-08-01], ~D[2026-08-01], retry_delay: 0)

    assert_received :iugu_attempt
    refute_received :iugu_attempt

    # Iugu's own 400 for the window arrives as a message, not a field.
    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"message" => "O maior intervalo permitido é de 3 dias"})
    end)

    assert {:error, %Error{kind: :validation, status: 400} = error} =
             Iugu.resend_webhooks_by_period(~D[2026-08-01], ~D[2026-08-03])

    assert error.messages == ["O maior intervalo permitido é de 3 dias"]
  end

  test "lists the deliveries of an invoice with the posted form body decoded into an event, and retries one accepting the non-JSON answer" do
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/web_hook_logs/LHB49MZZU4MW5KQ14FANL7T96CE5O2E6"

      Req.Test.json(conn, [
        %{
          "id" => "87ad0321-da96-44f0-b07e-3db1683be18l",
          "web_hook_id" => "QND6TZC2KXT5MN9I9IR44R3N3J94JBR5",
          "data" => %{
            "event" => "invoice.created",
            "data[id]" => "LHB49MZZU4MW5KQ14FANL7T96CE5O2E6",
            "data[status]" => "pending",
            "data[account_id]" => "LG7R5Y769EJK6XJT9LZS0KLZL4NAQ81L",
            "data[async_charged]" => "",
            "data[source]" => "api",
            "data[order_id]" => "GH1O585QN2YSZRF6WXZMMPR3NLGW1SQ8"
          },
          "status" => "success",
          "error" => "200",
          "loggable_id" => "LHB49MZZU4MW5KQ14FANL7T96CE5O2E6",
          "loggable_type" => "Invoice"
        },
        %{
          "id" => "unknown-event",
          "web_hook_id" => "QND6TZC2KXT5MN9I9IR44R3N3J94JBR5",
          "data" => %{"event" => "invoice.brand_new", "data[id]" => "X"},
          "status" => "success",
          "error" => "200",
          "loggable_id" => "X",
          "loggable_type" => "Invoice"
        }
      ])
    end)

    assert {:ok, [log, unknown]} = Iugu.list_webhook_logs("LHB49MZZU4MW5KQ14FANL7T96CE5O2E6")

    assert %{
             id: "87ad0321-da96-44f0-b07e-3db1683be18l",
             web_hook_id: "QND6TZC2KXT5MN9I9IR44R3N3J94JBR5",
             status: "success",
             http_status: 200,
             loggable_id: "LHB49MZZU4MW5KQ14FANL7T96CE5O2E6",
             loggable_type: "Invoice"
           } = log

    # The flat "data[id]" keys become the same nested map the receiver sees,
    # and from there the same event struct.
    assert log.payload == %{
             "event" => "invoice.created",
             "data" => %{
               "id" => "LHB49MZZU4MW5KQ14FANL7T96CE5O2E6",
               "status" => "pending",
               "account_id" => "LG7R5Y769EJK6XJT9LZS0KLZL4NAQ81L",
               "async_charged" => "",
               "source" => "api",
               "order_id" => "GH1O585QN2YSZRF6WXZMMPR3NLGW1SQ8"
             }
           }

    assert %Event{event: "invoice.created", account_id: "LG7R5Y769EJK6XJT9LZS0KLZL4NAQ81L"} =
             log.event

    assert Event.invoice_id(log.event) == "LHB49MZZU4MW5KQ14FANL7T96CE5O2E6"
    assert Event.order_id(log.event) == "GH1O585QN2YSZRF6WXZMMPR3NLGW1SQ8"
    assert Event.boolean_field(log.event, "async_charged") == nil

    assert unknown.event == nil
    assert unknown.payload["event"] == "invoice.brand_new"

    # The documented 200 body is `{ "Hook reenviado!" }`, which is not JSON:
    # a client decoding it would turn a success into a transport error.
    Req.Test.expect(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/v1/web_hook_logs/87ad0321-da96-44f0-b07e-3db1683be18l/retry"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, ~s({ "Hook reenviado!" }))
    end)

    assert {:ok, %{message: ~s({ "Hook reenviado!" })}} =
             Iugu.force_webhook_retry("87ad0321-da96-44f0-b07e-3db1683be18l")

    Req.Test.expect(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(404)
      |> Req.Test.json(%{"errors" => "Web hook log Not Found"})
    end)

    assert {:error, %Error{kind: :not_found, status: 404} = error} =
             Iugu.force_webhook_retry("nope")

    assert error.messages == ["Web hook log Not Found"]
  end
end
