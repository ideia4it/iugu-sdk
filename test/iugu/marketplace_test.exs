defmodule Iugu.MarketplaceTest do
  use ExUnit.Case, async: true

  alias Iugu
  alias Iugu.Error

  import Iugu.TestHelpers

  setup {Req.Test, :verify_on_exit!}

  test "creates a subaccount with a signed master request and default splits, keeps the three tokens, and refuses a name that would break the Pix key" do
    {private_key_pem, public_key} = generate_key_pair()

    expect_request_raw(fn conn, raw_body ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/v1/marketplace/create_account"

      # The master's live token is the SDK default; a signed call carries it
      # in the header and in the query, the way every official recipe does.
      assert_basic(conn, "iugu-test-token")
      assert conn.query_params == %{"api_token" => "iugu-test-token"}

      assert Jason.decode!(raw_body) == %{
               "name" => "Loja Ana",
               "splits" => [
                 %{
                   "recipient_account_id" => "MASTER",
                   "permit_aggregated" => true,
                   "pix_cents" => 499,
                   "pix_percent" => 4
                 }
               ]
             }

      assert_signed(conn, raw_body, public_key, "iugu-test-token")

      Req.Test.json(conn, %{
        "account_id" => "49196DF60BC64B6EB42DEC9C5D81C2CC",
        "name" => "Loja Ana",
        "live_api_token" => "LIVE-TOKEN",
        "test_api_token" => "TEST-TOKEN",
        "user_token" => "USER-TOKEN",
        "commissions" => nil
      })
    end)

    assert {:ok,
            %{
              account_id: "49196DF60BC64B6EB42DEC9C5D81C2CC",
              name: "Loja Ana",
              live_api_token: "LIVE-TOKEN",
              test_api_token: "TEST-TOKEN",
              user_token: "USER-TOKEN",
              body: %{"commissions" => nil}
            }} =
             Iugu.create_account("Loja Ana",
               splits: [
                 %{
                   recipient_account_id: "MASTER",
                   permit_aggregated: true,
                   pix_cents: 499,
                   pix_percent: 4
                 }
               ],
               signature_private_key: private_key_pem
             )

    # Without splits the body is the name alone: no "splits": null that the
    # signed document would have to carry as well.
    expect_request_raw(fn conn, raw_body ->
      assert raw_body == ~s({"name":"Barbearia do Zé"})

      Req.Test.json(conn, %{
        "account_id" => "ACC",
        "live_api_token" => "L",
        "test_api_token" => "T",
        "user_token" => "U"
      })
    end)

    assert {:ok, %{account_id: "ACC", name: nil}} =
             Iugu.create_account("Barbearia do Zé", signature_private_key: private_key_pem)

    # Iugu would accept these names and the Pix key would fail later at Banco
    # Central. No stub is standing, so refusing here is also proven to skip
    # the network.
    for name <- ["Loja 24h", "Ana & Bia", "Studio-Hair", ""] do
      assert {:error,
              %Error{kind: :validation, status: nil, path: "/v1/marketplace/create_account"}} =
               Iugu.create_account(name, signature_private_key: private_key_pem)
    end

    # A 200 without the tokens would leave the subaccount unreachable forever.
    Req.Test.stub(Iugu.Client, fn conn ->
      Req.Test.json(conn, %{"account_id" => "ACC"})
    end)

    assert {:error, %Error{kind: :unexpected, body: %{"account_id" => "ACC"}}} =
             Iugu.create_account("Loja Ana", signature_private_key: private_key_pem)

    # The one 400 worth retrying is the "one creation at a time" one.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{
        "errors" =>
          "Apenas uma criação de subconta pode ser processada por vez. Por favor, tente novamente em breve."
      })
    end)

    assert {:error, %Error{status: 400} = in_progress} =
             Iugu.create_account("Loja Ana", signature_private_key: private_key_pem)

    assert Iugu.account_creation_in_progress?(in_progress)

    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"errors" => "Essa conta não tem autorização de marketplace"})
    end)

    assert {:error, %Error{messages: ["Essa conta não tem autorização de marketplace"]} = denied} =
             Iugu.create_account("Loja Ana", signature_private_key: private_key_pem)

    refute Iugu.account_creation_in_progress?(denied)
    refute Iugu.account_creation_in_progress?(Error.validation("nome inválido"))

    # Every call creates a subaccount with a maintenance cost, so a timeout is
    # never retried, not even when the caller asks for it.
    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} =
             Iugu.create_account("Loja Ana",
               signature_private_key: private_key_pem,
               retry: :transient,
               retry_delay: 0
             )

    assert attempts() == 1
  end

  test "lists the subaccounts page by page with the master token and streams them until a short page, raising instead of returning a short list" do
    Req.Test.expect(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/marketplace"
      # The route's own ceiling is 1.000, so a bigger limit is clamped there.
      assert conn.query_params == %{"limit" => "1000", "start" => "50", "query" => "Ana"}
      assert_basic(conn, "iugu-test-token")
      assert_unsigned(conn)

      Req.Test.json(conn, %{
        "items" => [%{"id" => "ACC", "name" => "Loja Ana", "verified" => true}],
        "totalItems" => 51
      })
    end)

    assert {:ok,
            %{
              accounts: [%{"id" => "ACC", "name" => "Loja Ana", "verified" => true}],
              page_info: %{start: 50, limit: 1_000, total_items: 51}
            }} = Iugu.list_accounts(start: 50, limit: 5_000, query: "Ana")

    # The stream walks start = 0, 2, ... with the search on every page and
    # stops at the first page shorter than the limit, whatever totalItems
    # says.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.query_params["limit"] == "2"
      assert conn.query_params["query"] == "Loja"

      case conn.query_params["start"] do
        "0" ->
          Req.Test.json(conn, %{
            "items" => [%{"name" => "Loja Ana"}, %{"name" => "Loja Bia"}],
            "totalItems" => 2
          })

        "2" ->
          Req.Test.json(conn, %{"items" => [%{"name" => "Loja Clara"}], "totalItems" => 1})
      end
    end)

    assert ["Loja Ana", "Loja Bia", "Loja Clara"] =
             Iugu.stream_accounts(limit: 2, query: "Loja") |> Enum.map(& &1["name"])

    # Swallowing the error would read as "the marketplace has 2 subaccounts"
    # when it has 200.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{})
    end)

    assert_raise Error, fn -> Enum.to_list(Iugu.stream_accounts()) end
  end

  test "deactivates a subaccount with the master token, unsigned and without a retry, and surfaces the empty 400 Iugu documents" do
    expect_request(fn conn, body ->
      assert conn.method == "POST"
      assert conn.request_path == "/v1/marketplace/deactivate"
      assert body == %{"account_id" => "ACC"}
      assert conn.query_string == ""
      assert_basic(conn, "iugu-test-token")
      assert_unsigned(conn)

      Req.Test.json(conn, %{
        "success" => true,
        "message" =>
          "A conta está em processo de desativação, em alguns instantes será finalizado."
      })
    end)

    assert {:ok, %{"success" => true, "message" => "A conta está em processo" <> _rest}} =
             Iugu.deactivate_account("ACC")

    # The docs only show `{}` for the 400 (a remaining balance is the likely
    # cause), so the error arrives with no message rather than a crash.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{})
    end)

    assert {:error, %Error{kind: :validation, status: 400, messages: []}} =
             Iugu.deactivate_account("ACC")

    stub_counting_transport_error()

    assert {:error, %Error{kind: :transport}} = Iugu.deactivate_account("ACC")
    assert attempts() == 1
  end

  test "manages a subaccount's API tokens with the master_token and a signature on every call, refusing a type outside LIVE/TEST" do
    {private_key_pem, public_key} = generate_key_pair()

    expect_request_raw(fn conn, raw_body ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "POST"
      assert conn.request_path == "/v1/ACC/api_tokens"
      # The master_token is not the live token, so it never comes from config.
      assert_basic(conn, "MASTER-TOKEN")
      assert conn.query_params == %{"api_token" => "MASTER-TOKEN"}
      assert raw_body == ~s({"api_type":"LIVE","description":"Integração Loja"})
      assert_signed(conn, raw_body, public_key, "MASTER-TOKEN")

      Req.Test.json(conn, %{
        "id" => "TOKEN-ID",
        "token" => "FULL-TOKEN-SHOWN-ONCE",
        "api_type" => "LIVE",
        "description" => "Integração Loja",
        "status" => "active"
      })
    end)

    assert {:ok, %{"id" => "TOKEN-ID", "token" => "FULL-TOKEN-SHOWN-ONCE"}} =
             Iugu.create_api_token("ACC", "LIVE", "Integração Loja",
               api_token: "MASTER-TOKEN",
               signature_private_key: private_key_pem
             )

    # The listing is a signed GET: the third line of the document is empty
    # and the tokens come back masked.
    expect_request_raw(fn conn, raw_body ->
      conn = Plug.Conn.fetch_query_params(conn)

      assert conn.method == "GET"
      assert conn.request_path == "/v1/MASTER/api_tokens"
      assert raw_body == ""
      assert_basic(conn, "MASTER-TOKEN")
      assert_signed(conn, "", public_key, "MASTER-TOKEN")

      Req.Test.json(conn, %{
        "referrer_id" => "MASTER",
        "accounts" => %{
          "ACC" => %{
            "live_token" => "B2C614**********************************************************",
            "live_token_status" => "active",
            "test_token" => "CF0F19**********************************************************",
            "test_token_status" => "active",
            "user_token" => "BF0A58**********************************************************"
          }
        }
      })
    end)

    assert {:ok,
            %{"referrer_id" => "MASTER", "accounts" => %{"ACC" => %{"live_token" => masked}}}} =
             Iugu.list_api_tokens("MASTER",
               api_token: "MASTER-TOKEN",
               signature_private_key: private_key_pem
             )

    assert masked =~ ~r/\AB2C614\*+\z/

    expect_request_raw(fn conn, raw_body ->
      assert conn.method == "DELETE"
      assert conn.request_path == "/v1/ACC/api_tokens/TOKEN-ID"
      assert raw_body == ""
      assert_signed(conn, "", public_key, "MASTER-TOKEN")

      Req.Test.json(conn, %{"id" => "TOKEN-ID", "api_type" => "LIVE", "status" => "active"})
    end)

    assert {:ok, %{"id" => "TOKEN-ID"}} =
             Iugu.delete_api_token("ACC", "TOKEN-ID",
               api_token: "MASTER-TOKEN",
               signature_private_key: private_key_pem
             )

    # The 400 of this route is the list-of-strings error shape.
    Req.Test.stub(Iugu.Client, fn conn ->
      conn
      |> Plug.Conn.put_status(400)
      |> Req.Test.json(%{"errors" => ["Description não pode ficar em branco"]})
    end)

    assert {:error, %Error{kind: :validation, messages: ["Description não pode ficar em branco"]}} =
             Iugu.create_api_token("ACC", "TEST", "",
               api_token: "MASTER-TOKEN",
               signature_private_key: private_key_pem
             )

    # No mock is consumed, so Iugu is never asked to answer 400 for a type
    # we could have refused here.
    assert {:error,
            %Error{
              kind: :validation,
              status: nil,
              path: "/v1/ACC/api_tokens",
              messages: [message]
            }} =
             Iugu.create_api_token("ACC", "live", "Integração", api_token: "MASTER-TOKEN")

    assert message =~ "api_type"

    assert Iugu.api_types() == ["LIVE", "TEST"]
  end
end
