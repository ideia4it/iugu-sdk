defmodule Iugu.Signature do
  @moduledoc """
  Assinatura RSA das requisições à Iugu.

  As rotas de cash out, criação de subconta, configuração de conta, domicílio
  bancário e tokens de API exigem três headers além do token: `Request-Time`,
  `Signature` e, opcional, `X-Signature-Token-Id`. A assinatura cobre um
  documento de exatamente três linhas separadas por `\\n`:

      METHOD|PATH
      TOKEN|REQUEST_TIME
      BODY

    * `METHOD` é o verbo em maiúsculas.
    * `PATH` inclui o `/v1` e os ids reais, e **não** inclui host nem query
      string (`?api_token=` fica de fora).
    * `TOKEN` é o `api_token` cru que autentica a chamada. No fluxo whitelabel
      do marketplace é o `live_api_token` da **subconta**, assinado com a chave
      privada da conta mestre.
    * `REQUEST_TIME` é o mesmo valor, byte a byte, do header `Request-Time`.
    * `BODY` são os bytes exatos enviados na requisição, sem nenhum espaço
      fora de valor de string. Sem corpo (GET), a linha fica vazia; a
      documentação não mostra esse caso e todas as receitas oficiais montam as
      três linhas incondicionalmente, então **confirme contra a conta** antes
      de depender de uma rota assinada sem corpo.

  O algoritmo é SHA-256 com RSA PKCS#1 v1.5 (`openssl dgst -sha256 -sign`), e
  o resultado vai em Base64 estrito, numa linha só, com o prefixo literal
  `signature=`.

  Este módulo é uma função pura: recebe o instante da requisição em vez de
  ler o relógio, para que o teste confira a assinatura com a chave pública.
  A Iugu tolera até 5 minutos entre `Request-Time` e a chegada, então quem
  chama gera o instante imediatamente antes de enviar e nunca reaproveita uma
  assinatura em outra requisição.

  A assinatura só existe em produção (`live_mode`); com `test_api_token` a
  Iugu não valida chave nenhuma.
  """

  @signature_prefix "signature="

  @doc """
  Monta o documento assinado, exatamente como a Iugu o reconstrói do outro
  lado.

      iex> Iugu.Signature.content_to_sign(
      ...>   "POST",
      ...>   "/v1/marketplace/create_account",
      ...>   "ABC123",
      ...>   ~U[2024-06-15 15:21:29Z],
      ...>   ~s({"name":"Nome da Subconta"})
      ...> )
      "POST|/v1/marketplace/create_account\\nABC123|2024-06-15T15:21:29Z\\n{\\"name\\":\\"Nome da Subconta\\"}"

  Sem corpo, a terceira linha fica vazia e o documento termina no `\\n`:

      iex> Iugu.Signature.content_to_sign("GET", "/v1/ACC/api_tokens", "T", ~U[2024-06-15 15:21:29Z], "")
      "GET|/v1/ACC/api_tokens\\nT|2024-06-15T15:21:29Z\\n"
  """
  @spec content_to_sign(String.t(), String.t(), String.t(), DateTime.t() | String.t(), binary()) ::
          String.t()
  def content_to_sign(method, path, api_token, request_time, body)
      when is_binary(method) and is_binary(path) and is_binary(api_token) and is_binary(body) do
    "#{String.upcase(method)}|#{path}\n#{api_token}|#{format_request_time(request_time)}\n#{body}"
  end

  @doc """
  Assina o documento com a chave privada em PEM e devolve o Base64.

  Aceita PEM PKCS#1 (`BEGIN RSA PRIVATE KEY`, o que `openssl genrsa` gera) e
  PKCS#8 (`BEGIN PRIVATE KEY`).
  """
  @spec sign(String.t(), String.t()) :: String.t()
  def sign(content, private_key_pem) when is_binary(content) and is_binary(private_key_pem) do
    content
    |> :public_key.sign(:sha256, decode_private_key(private_key_pem))
    |> Base.encode64()
  end

  @doc """
  Headers de uma requisição assinada.

  Opções obrigatórias: `:api_token`, `:private_key` (PEM) e `:request_time`
  (`DateTime` ou string ISO 8601 já formatada). `:token_id` é opcional e vira
  o header `X-Signature-Token-Id`.

  Os nomes saem com a capitalização da documentação; HTTP não distingue, e o
  Req os normaliza em minúsculas de qualquer forma.
  """
  @spec headers(String.t(), String.t(), binary(), keyword()) :: [{String.t(), String.t()}]
  def headers(method, path, body, opts) do
    api_token = Keyword.fetch!(opts, :api_token)
    private_key = Keyword.fetch!(opts, :private_key)
    request_time = opts |> Keyword.fetch!(:request_time) |> format_request_time()

    signature =
      method
      |> content_to_sign(path, api_token, request_time, body)
      |> sign(private_key)

    [
      {"Request-Time", request_time},
      {"Signature", @signature_prefix <> signature}
    ] ++ token_id_header(Keyword.get(opts, :token_id))
  end

  # ISO 8601 com precisão de segundos: as receitas oficiais usam
  # `Time.now.iso8601` e `utcnow().replace(microsecond=0)`, e a fração de
  # segundo só aumenta a chance de header e documento divergirem.
  defp format_request_time(%DateTime{} = request_time) do
    request_time
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_request_time(request_time) when is_binary(request_time), do: request_time

  defp token_id_header(nil), do: []
  defp token_id_header(token_id), do: [{"X-Signature-Token-Id", token_id}]

  defp decode_private_key(private_key_pem) do
    case :public_key.pem_decode(private_key_pem) do
      [entry | _rest] ->
        :public_key.pem_entry_decode(entry)

      [] ->
        raise ArgumentError,
              "a chave privada RSA da Iugu não é um PEM válido (esperava BEGIN RSA PRIVATE KEY ou BEGIN PRIVATE KEY)"
    end
  end
end
