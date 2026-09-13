defmodule Iugu.Webhook.SyncTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  setup {Req.Test, :verify_on_exit!}

  @url "https://app.example.com/v1/webhooks/iugu"
  @other_url "https://outro.example/hook"

  test "creates one trigger per event with the configured secret, is safe to re-run, updates a stale secret, reports inactive and duplicated ones and prunes only when asked" do
    test_pid = self()

    Req.Test.stub(Iugu.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v1/web_hooks/supported_events"} ->
          Req.Test.json(conn, ["all", "invoice.status_changed", "referrals.verification"])

        {"GET", "/v1/web_hooks"} ->
          Req.Test.json(conn, [])

        {"POST", "/v1/web_hooks"} ->
          {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:created, Jason.decode!(raw_body)})
          Req.Test.json(conn, %{"id" => "new", "active" => true})
      end
    end)

    assert {:ok, report} = Iugu.sync_webhooks(@url, request_interval_ms: 0)

    # "all" is dropped from the default list: with the individual events it
    # would deliver everything twice. The configured secret rides on every
    # created trigger, otherwise Iugu calls us and we reject it.
    assert Enum.map(report.created, & &1.event) == [
             "invoice.status_changed",
             "referrals.verification"
           ]

    assert_received {:created, trigger}
    assert trigger["authorization"] == "iugu-test-webhook-authorization"
    assert trigger["url"] == @url
    assert trigger["event"] == "invoice.status_changed"
    refute Map.has_key?(trigger, "active")
    assert_received {:created, %{"event" => "referrals.verification"}}

    # A second run creates nothing, so the task is safe to re-run.
    stub_api(
      events: ["invoice.status_changed"],
      existing: [trigger("a", "invoice.status_changed")]
    )

    assert {:ok, report} = Iugu.sync_webhooks(@url, request_interval_ms: 0)

    assert report.created == []
    assert report.updated == []
    assert Enum.map(report.unchanged, & &1.event) == ["invoice.status_changed"]

    # Iugu has an update route, so a trigger carrying another secret is fixed
    # in place instead of recreated.
    stub_api(
      events: ["invoice.status_changed"],
      existing: [trigger("a", "invoice.status_changed", authorization: "old")]
    )

    assert {:ok, report} = Iugu.sync_webhooks(@url, request_interval_ms: 0)

    assert report.created == []
    assert Enum.map(report.updated, & &1.id) == ["a"]
    assert_received {:updated, "a", %{"authorization" => "iugu-test-webhook-authorization"}}

    # Without a secret to enforce, nothing is updated.
    stub_api(
      events: ["invoice.status_changed"],
      existing: [trigger("a", "invoice.status_changed", authorization: "old")]
    )

    assert {:ok, %{updated: [], unchanged: [%{id: "a"}]}} =
             Iugu.sync_webhooks(@url, authorization: nil, request_interval_ms: 0)

    # An inactive trigger is reported, never touched: nothing documented
    # reactivates it.
    stub_api(
      events: ["invoice.status_changed"],
      existing: [trigger("a", "invoice.status_changed", active: false, authorization: "old")]
    )

    assert {:ok, report} = Iugu.sync_webhooks(@url, request_interval_ms: 0)

    assert report.created == []
    assert report.updated == []
    assert report.unchanged == []
    assert Enum.map(report.inactive, & &1.event) == ["invoice.status_changed"]

    # Iugu keeps duplicates; they are reported, and only prune removes them,
    # along with the triggers of this url whose event left the list. Triggers
    # of other urls are never touched.
    existing = [
      trigger("a", "invoice.status_changed"),
      trigger("dup", "invoice.status_changed"),
      trigger("old", "invoice.created"),
      trigger("theirs", "all", url: @other_url)
    ]

    stub_api(events: ["invoice.status_changed"], existing: existing)

    assert {:ok, report} = Iugu.sync_webhooks(@url, request_interval_ms: 0)

    assert Enum.map(report.duplicated, & &1.id) == ["dup"]
    assert report.deleted == []
    refute_received {:deleted, _id}

    stub_api(events: ["invoice.status_changed"], existing: existing)

    assert {:ok, report} = Iugu.sync_webhooks(@url, prune: true, request_interval_ms: 0)

    assert Enum.map(report.deleted, & &1.id) |> Enum.sort() == ["dup", "old"]
    assert_received {:deleted, "old"}
    assert_received {:deleted, "dup"}
    refute_received {:deleted, "theirs"}

    # remove_all drops every trigger of that url, whatever the event list says,
    # and still leaves the other url alone.
    stub_api(
      events: [],
      existing: [
        trigger("a", "invoice.status_changed"),
        trigger("b", "invoice.created"),
        trigger("theirs", "all", url: @other_url)
      ]
    )

    assert {:ok, report} = Iugu.remove_all_webhooks(@url, request_interval_ms: 0)

    assert Enum.map(report.deleted, & &1.event) |> Enum.sort() == [
             "invoice.created",
             "invoice.status_changed"
           ]

    refute_received {:deleted, "theirs"}
  end

  test "narrows the list with only/except, accepts an explicit list without asking the API, forwards the token and dry-runs without writing" do
    stub_api(
      events: ["invoice.status_changed", "invoice.created", "referrals.verification"],
      existing: []
    )

    assert {:ok, report} =
             Iugu.sync_webhooks(@url,
               only: ["invoice.status_changed", "invoice.created"],
               except: ["invoice.created"],
               request_interval_ms: 0
             )

    assert Enum.map(report.created, & &1.event) == ["invoice.status_changed"]

    # With an explicit event list the events endpoint is never called, and the
    # subaccount token given to the sync reaches every request.
    Req.Test.stub(Iugu.Client, fn conn ->
      refute conn.request_path == "/v1/web_hooks/supported_events"

      assert Plug.Conn.get_req_header(conn, "authorization") == [
               "Basic " <> Base.encode64("SUB-TOKEN:")
             ]

      case conn.method do
        "GET" -> Req.Test.json(conn, [])
        "POST" -> Req.Test.json(conn, %{"id" => "new"})
      end
    end)

    assert {:ok, %{created: [%{event: "all", id: "new"}]}} =
             Iugu.sync_webhooks(@url,
               events: ["all"],
               api_token: "SUB-TOKEN",
               request_interval_ms: 0
             )

    # A dry run reads the plan and issues no write: every request stays a GET.
    Req.Test.stub(Iugu.Client, fn conn ->
      assert conn.method == "GET"

      case conn.request_path do
        "/v1/web_hooks/supported_events" ->
          Req.Test.json(conn, ["invoice.status_changed"])

        "/v1/web_hooks" ->
          Req.Test.json(conn, [
            trigger("stale", "invoice.created", authorization: "old"),
            trigger("dup", "invoice.created", authorization: "old")
          ])
      end
    end)

    assert {:ok, report} =
             Iugu.sync_webhooks(@url, prune: true, dry_run: true, request_interval_ms: 0)

    assert report.dry_run
    assert Enum.map(report.created, & &1.event) == ["invoice.status_changed"]
    assert Enum.all?(report.created, &is_nil(&1.id))
    assert Enum.map(report.deleted, & &1.id) == ["stale", "dup"]
    assert report.failed == []
  end

  test "refuses a plan over the trigger limit before writing, reports a failed creation instead of aborting, and aborts when the lists cannot be read" do
    # Twenty events at one trigger each already fill the account; nothing is
    # written and the caller is pointed at only: or events: ["all"].
    events = Enum.map(1..21, &"invoice.event_#{&1}")

    Req.Test.stub(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      Req.Test.json(conn, [])
    end)

    assert {:error, %Error{kind: :validation, status: nil} = error} =
             Iugu.sync_webhooks(@url, events: events, request_interval_ms: 0)

    assert hd(error.messages) =~ "21 gatilhos"

    # Triggers of other urls count toward the same account limit, and a prune
    # frees room in the same plan.
    stub_api(
      events: ["invoice.status_changed"],
      existing:
        Enum.map(1..19, &trigger("other-#{&1}", "invoice.event_#{&1}", url: @other_url)) ++
          [trigger("old", "invoice.created")]
    )

    assert {:error, %Error{kind: :validation}} = Iugu.sync_webhooks(@url, request_interval_ms: 0)

    stub_api(
      events: ["invoice.status_changed"],
      existing:
        Enum.map(1..19, &trigger("other-#{&1}", "invoice.event_#{&1}", url: @other_url)) ++
          [trigger("old", "invoice.created")]
    )

    assert {:ok, %{created: [%{event: "invoice.status_changed"}], deleted: [%{id: "old"}]}} =
             Iugu.sync_webhooks(@url, prune: true, request_interval_ms: 0)

    # The account that really allows thirty says so.
    Req.Test.stub(Iugu.Client, fn conn ->
      case conn.method do
        "GET" -> Req.Test.json(conn, [])
        "POST" -> Req.Test.json(conn, %{"id" => "new"})
      end
    end)

    assert {:ok, %{created: created}} =
             Iugu.sync_webhooks(@url, events: events, max_triggers: 30, request_interval_ms: 0)

    assert length(created) == 21

    # One refused event does not stop the others.
    Req.Test.stub(Iugu.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v1/web_hooks/supported_events"} ->
          Req.Test.json(conn, ["invoice.status_changed", "invoice.brand_new"])

        {"GET", "/v1/web_hooks"} ->
          Req.Test.json(conn, [])

        {"POST", "/v1/web_hooks"} ->
          {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

          if Jason.decode!(raw_body)["event"] == "invoice.brand_new" do
            conn
            |> Plug.Conn.put_status(422)
            |> Req.Test.json(%{"errors" => %{"event" => ["is invalid."]}})
          else
            Req.Test.json(conn, %{"id" => "new"})
          end
      end
    end)

    assert {:ok, report} = Iugu.sync_webhooks(@url, request_interval_ms: 0)

    assert Enum.map(report.created, & &1.event) == ["invoice.status_changed"]

    assert [%{event: "invoice.brand_new", error: %Error{kind: :validation, status: 422}}] =
             report.failed

    # Without the event list there is no plan, so nothing is created at all.
    Req.Test.stub(Iugu.Client, fn conn ->
      assert conn.method == "GET"
      conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{})
    end)

    assert {:error, %Error{kind: :unauthorized}} =
             Iugu.sync_webhooks(@url, request_interval_ms: 0)
  end

  defp trigger(id, event, opts \\ []) do
    %{
      "id" => id,
      "event" => event,
      "url" => Keyword.get(opts, :url, @url),
      "authorization" => Keyword.get(opts, :authorization, "iugu-test-webhook-authorization"),
      "active" => Keyword.get(opts, :active, true)
    }
  end

  defp stub_api(opts) do
    events = Keyword.fetch!(opts, :events)
    existing = Keyword.fetch!(opts, :existing)
    test_pid = self()

    Req.Test.stub(Iugu.Client, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v1/web_hooks/supported_events"} ->
          Req.Test.json(conn, events)

        {"GET", "/v1/web_hooks"} ->
          Req.Test.json(conn, existing)

        {"POST", "/v1/web_hooks"} ->
          Req.Test.json(conn, %{"id" => "new", "active" => true})

        {"PUT", "/v1/web_hooks/" <> id} ->
          {:ok, raw_body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:updated, id, Jason.decode!(raw_body)})
          Req.Test.json(conn, %{"id" => id, "active" => true})

        {"DELETE", "/v1/web_hooks/" <> id} ->
          send(test_pid, {:deleted, id})
          Req.Test.json(conn, %{"id" => id})
      end
    end)
  end
end
