defmodule Iugu.ConfigTest do
  # Mutates application env, so it cannot share the node with async tests.
  use ExUnit.Case, async: false

  alias Iugu.Config

  setup do
    original = Application.get_all_env(:iugu_sdk)

    on_exit(fn ->
      Enum.each(Application.get_all_env(:iugu_sdk), fn {key, _} ->
        Application.delete_env(:iugu_sdk, key)
      end)

      Application.put_all_env(iugu_sdk: original)
    end)

    {:ok, original: original}
  end

  test "reads the token and the endpoint, falls back for what is optional and fails loudly for what a signed call cannot do without",
       %{original: _original} do
    assert Config.api_token!() == "iugu-test-token"

    # There is no sandbox host: the token picks the environment.
    assert Config.base_url() == "https://api.iugu.com"

    Application.put_env(:iugu_sdk, :receive_timeout, 1_234)
    assert Config.receive_timeout() == 1_234

    Application.delete_env(:iugu_sdk, :receive_timeout)
    assert Config.receive_timeout() == :timer.seconds(30)

    # Only the signed routes need the key pair, so its absence is not an error
    # until one of them is called.
    assert Config.signature_private_key() == nil
    assert Config.signature_token_id() == nil

    assert_raise RuntimeError, ~r/IUGU_SIGNATURE_PRIVATE_KEY/, fn ->
      Config.signature_private_key!()
    end

    Application.put_env(:iugu_sdk, :signature_private_key, "-----BEGIN PEM-----")
    Application.put_env(:iugu_sdk, :signature_token_id, "TOKEN-ID")

    assert Config.signature_private_key!() == "-----BEGIN PEM-----"
    assert Config.signature_token_id() == "TOKEN-ID"

    # The webhook secret is what Iugu echoes back in the Authorization header
    # of every delivery; the receiver compares against it.
    assert Config.webhook_authorization() == "iugu-test-webhook-authorization"

    Application.delete_env(:iugu_sdk, :webhook_authorization)
    assert Config.webhook_authorization() == nil

    # Iugu answers 401 with no documented body, and a 401 is indistinguishable
    # from a token pending approval. Failing here points at the config instead.
    Application.put_env(:iugu_sdk, :api_token, nil)

    assert_raise RuntimeError, ~r/IUGU_API_TOKEN/, fn -> Config.api_token!() end
  end
end
