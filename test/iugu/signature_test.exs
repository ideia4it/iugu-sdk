defmodule Iugu.SignatureTest do
  use ExUnit.Case, async: true

  alias Iugu.Signature

  import Iugu.TestHelpers

  doctest Iugu.Signature

  @token "ABC123DEF45D4B9E27C8126BE74850A4366492313823D1811114769BD0D5F0B0"

  test "builds the documented three line document, signs it so Iugu's public key verifies it and emits the three headers" do
    {private_key_pem, public_key} = generate_key_pair()

    # Straight from the Criar Subconta docs: method|path, token|time, raw body.
    body =
      ~s({"name":"Nome da Subconta","splits":[{"recipient_account_id":"account_id","cents":20}]})

    assert Signature.content_to_sign(
             "post",
             "/v1/marketplace/create_account",
             @token,
             "2024-06-15T12:21:29-03:00",
             body
           ) ==
             "POST|/v1/marketplace/create_account\n" <>
               "#{@token}|2024-06-15T12:21:29-03:00\n" <>
               body

    request_time = ~U[2024-06-15 15:21:29.123456Z]

    headers =
      Signature.headers("POST", "/v1/marketplace/create_account", body,
        api_token: @token,
        private_key: private_key_pem,
        request_time: request_time,
        token_id: "8D3EA0B0F546405B880F1BAC7B2CA5A7"
      )

    # Seconds precision: a fractional second in the header and none in the
    # document (or the other way around) is an Invalid Elapsed Time.
    assert {"Request-Time", "2024-06-15T15:21:29Z"} in headers
    assert {"X-Signature-Token-Id", "8D3EA0B0F546405B880F1BAC7B2CA5A7"} in headers

    {"Signature", "signature=" <> encoded_signature} =
      List.keyfind(headers, "Signature", 0)

    expected_content =
      Signature.content_to_sign(
        "POST",
        "/v1/marketplace/create_account",
        @token,
        "2024-06-15T15:21:29Z",
        body
      )

    # Strict Base64, single line, no wrapping: openssl base64 -A.
    {:ok, signature} = Base.decode64(encoded_signature)

    assert :public_key.verify(expected_content, :sha256, signature, public_key)

    # The signature is bound to these exact bytes: one changed byte in the
    # body, the path, the token or the time invalidates it.
    for tampered <- [
          String.replace(expected_content, "cents\":20", "cents\":21"),
          String.replace(expected_content, "/v1/marketplace", "/v1/marketplaces"),
          String.replace(expected_content, @token, "OTHER"),
          String.replace(expected_content, "15:21:29", "15:21:30")
        ] do
      refute :public_key.verify(tampered, :sha256, signature, public_key)
    end

    # Without a token id there is no header, since Iugu treats its absence as
    # "keep the current behaviour" rather than an empty id.
    unsigned_id_headers =
      Signature.headers("GET", "/v1/ACC/api_tokens", "",
        api_token: @token,
        private_key: private_key_pem,
        request_time: request_time
      )

    assert Enum.map(unsigned_id_headers, &elem(&1, 0)) == ["Request-Time", "Signature"]

    # A bodiless GET signs an empty third line.
    {"Signature", "signature=" <> get_signature} =
      List.keyfind(unsigned_id_headers, "Signature", 0)

    assert :public_key.verify(
             "GET|/v1/ACC/api_tokens\n#{@token}|2024-06-15T15:21:29Z\n",
             :sha256,
             Base.decode64!(get_signature),
             public_key
           )
  end

  test "loads the key from a PKCS#1 or a PKCS#8 PEM and refuses anything that is not a PEM" do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    # The RSAPrivateKey record carries the modulus and the public exponent in
    # positions 2 and 3.
    public_key = {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}
    content = "POST|/v1/signature/validate\n#{@token}|2025-04-24T18:12:00Z\n{\"RAW_BODY\":\"x\"}"

    # `openssl genrsa` writes PKCS#1 (BEGIN RSA PRIVATE KEY); the Java recipe
    # and most secret managers hand out PKCS#8 (BEGIN PRIVATE KEY).
    for pem_type <- [:RSAPrivateKey, :PrivateKeyInfo] do
      pem = :public_key.pem_encode([:public_key.pem_entry_encode(pem_type, private_key)])

      signature = content |> Signature.sign(pem) |> Base.decode64!()

      assert :public_key.verify(content, :sha256, signature, public_key)
    end

    assert_raise ArgumentError, ~r/PEM/, fn -> Signature.sign(content, "not a pem") end
  end
end
