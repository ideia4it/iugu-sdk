defmodule Iugu.Client do
  @moduledoc """
  Único ponto que fala HTTP com a Iugu.

  Autenticação é HTTP Basic com o token como usuário e senha vazia:
  `Authorization: Basic Base64("TOKEN:")`. É o método que a documentação
  recomenda ("sendo o mais recomendado o uso do HTTP Basic Auth").

  A `base_url` é só o host (`https://api.iugu.com`). O prefixo `/v1` fica no
  caminho de cada recurso porque ele faz parte da string assinada no RSA, e
  não há host de sandbox: o `test_api_token` seleciona o modo de teste no
  mesmo endereço.

  ## Tokens

  Por padrão as chamadas saem com o token da conta mestre
  (`Iugu.Config.api_token!/0`). Para agir como uma subconta, ou para
  as poucas rotas que exigem `user_token` ou `master_token`, passe
  `:api_token`:

      Client.get("/v1/accounts/\#{id}", api_token: subaccount.live_api_token)

  Uma única rota documentada não usa token nenhum: `POST /v1/payment_token`
  ("A API de Criação de Token não utiliza a autenticação via api_token"; o
  `account_id` do corpo identifica a conta). Nela, `api_token: :none` sai
  sem o header `Authorization`, porque a tabela de erros lista `api_token:
  está invalido` para essa rota e o token da mestre não é necessariamente o
  da conta que vai guardar o cartão.

  ## Assinatura RSA (`sign: true`)

  As rotas de cash out (`/v1/transfer_requests`, `/v1/accounts/{id}/request_withdraw`,
  `/v1/transfers`, `/v1/payment_requests`), criação de subconta
  (`/v1/marketplace/create_account`), configuração de conta
  (`/v1/accounts/configuration`), domicílio bancário (`/v1/bank_verification`),
  tokens de API (`/v1/{account_id}/api_tokens`) e `/v1/signature/validate`
  exigem os headers `Request-Time` e `Signature` (mais `X-Signature-Token-Id`,
  opcional, quando a conta tem mais de um token LIVE com RSA). Nelas, passe
  `sign: true`:

      Client.post("/v1/marketplace/create_account", %{name: "Loja Ana"}, sign: true)

  A assinatura cobre os bytes exatos do corpo enviado, então ela é calculada
  num passo do Req anexado **depois** de `encode_body`: o JSON é codificado
  uma vez, assinado e enviado tal qual. Assinar o mapa e deixar o Req
  codificar de novo produziria `Invalid Signature` sem nenhum aviso.

  Os exemplos oficiais de rota assinada mandam o token em `?api_token=` na
  query string, e a documentação não diz se o Basic basta nessas rotas. Por
  isso uma chamada assinada manda o token dos dois jeitos: no header e na
  query. A query não entra na string assinada, então isso é seguro; confirme
  contra a conta se quiser tirar um dos dois.

  A chave privada vem de `Iugu.Config.signature_private_key!/0` ou
  da opção `:signature_private_key`; o id do token, de
  `Iugu.Config.signature_token_id/0` ou `:signature_token_id`. No
  fluxo whitelabel do marketplace a chave é a da conta mestre e o
  `:api_token` é o `live_api_token` da subconta, sem chave própria.
  `validate_signature/2` confere a rotina inteira contra a Iugu sem mover
  dinheiro.

  ## Retry

  `get/2` repete em falha transitória; `post/3`, `put/3` e `delete/2` não
  repetem por padrão. A maioria das rotas de escrita da Iugu não aceita chave
  de idempotência (saque, criação de subconta, configuração de conta, tokens),
  e nelas um retry em timeout ou 429 gera uma segunda movimentação de dinheiro
  ou uma segunda subconta. Quem sabe que a chamada é idempotente liga o retry
  explicitamente. As rotas que aceitam `Idempotency-Key` (fatura, assinatura,
  cliente, cobrança direta, transferência entre contas, Pix e TED para
  terceiros) ficam seguras com o header, e `idempotency_options/2` monta as
  opções certas a partir da chave:

      Client.post("/v1/invoices", body, Client.idempotency_options(opts, key))

  Num POST o valor certo é `:transient`, não `:safe_transient`:
  `:safe_transient` só considera GET e HEAD seguros, então num POST ele
  repetiria apenas em 429 e 503, deixando o timeout de fora.
  """

  alias Iugu.Config
  alias Iugu.Error
  alias Iugu.Signature

  @client_options [:api_token, :base_url]
  @signature_options [:sign, :signature_private_key, :signature_token_id]
  @signature_validate_path "/v1/signature/validate"

  @type signature_check :: %{
          message: String.t() | nil,
          request_body: String.t() | nil,
          status: String.t() | nil
        }

  @doc """
  Monta o `Req.Request` da Iugu.

  Aceita `:api_token` para falar por uma subconta (ou com `user_token` e
  `master_token` nas rotas que os exigem) e `:base_url`.

  A ordem dos dois `Keyword.merge/2` importa: o padrão do SDK entra primeiro,
  `:req_options` sobrepõe (é assim que o teste injeta o `plug`), e a
  opção passada aqui sobrepõe as duas. Ao contrário, uma chave nova em
  `:req_options` passaria a descartar em silêncio o que o chamador pediu.
  """
  @spec new(keyword()) :: Req.Request.t()
  def new(opts \\ []) do
    {client_opts, req_opts} = Keyword.split(opts, @client_options)

    [
      base_url: Keyword.get(client_opts, :base_url) || Config.base_url(),
      headers:
        authorization_header(Keyword.get(client_opts, :api_token) || Config.api_token!()) ++
          [accept: "application/json"],
      receive_timeout: Config.receive_timeout(),
      retry: false,
      finch: [pool_max_idle_time: :timer.seconds(60)]
    ]
    |> Keyword.merge(Application.get_env(:iugu_sdk, :req_options, []))
    |> Keyword.merge(req_opts)
    |> Req.new()
  end

  @doc "GET com retry em falha transitória."
  @spec get(String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def get(path, opts \\ []) do
    request(:get, path, Keyword.put_new(opts, :retry, :safe_transient))
  end

  @doc "POST sem retry. Veja a nota sobre idempotência no moduledoc."
  @spec post(String.t(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def post(path, body, opts \\ []) do
    request(:post, path, Keyword.put(opts, :json, body))
  end

  @doc "PUT sem retry. Veja a nota sobre idempotência no moduledoc."
  @spec put(String.t(), map(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def put(path, body, opts \\ []) do
    request(:put, path, Keyword.put(opts, :json, body))
  end

  @doc "DELETE sem retry."
  @spec delete(String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def delete(path, opts \\ []), do: request(:delete, path, opts)

  @doc """
  Opções de uma escrita que aceita `Idempotency-Key`.

  Com a chave, o header entra e o retry liga em `:transient` (a menos que o
  chamador tenha passado `retry:`), porque a Iugu recusa a repetição com 409
  em vez de criar de novo. Sem chave o retry é **forçado desligado**, mesmo
  que o chamador o tenha pedido: um timeout pode ter criado a fatura ou
  debitado a transferência, e a segunda tentativa faria de novo.
  """
  @spec idempotency_options(keyword(), String.t() | nil) :: keyword()
  def idempotency_options(req_opts, nil), do: Keyword.put(req_opts, :retry, false)

  def idempotency_options(req_opts, idempotency_key) when is_binary(idempotency_key) do
    req_opts
    |> Keyword.update(:headers, ["idempotency-key": idempotency_key], fn headers ->
      Keyword.put(headers, :"idempotency-key", idempotency_key)
    end)
    |> Keyword.put_new(:retry, :transient)
  end

  @doc """
  Confere a rotina de assinatura RSA contra a Iugu, sem mover dinheiro.

  `POST /v1/signature/validate` "não torna uma assinatura válida, apenas a
  verifica": o retorno `"message": "Signature check successful"` "serve
  apenas para validar que o seu script seguiu a lógica correta". É o único
  jeito de saber que a chave privada, o relógio e o documento assinado
  estão certos antes do primeiro saque ou da primeira subconta, então rode
  uma vez ao configurar a conta e sempre que trocar a chave.

  `message` vai no corpo como `RAW_BODY`, o único campo que a rota
  documenta. A resposta traz `message`, `status` (`"ok"`) e `request_body`,
  o corpo cru como a Iugu o recebeu, para comparar com o que foi assinado.
  Falhas voltam como 422 `Public Key Not Found`, `Invalid Elapsed Time` ou
  `Invalid Signature`.

  Só existe em produção e com a chave da **própria** conta do token: "Este
  é o único endpoint que o Fluxo Whitelabel não é compatível", então o
  `live_api_token` de uma subconta assinado com a chave da mestre falha
  aqui mesmo funcionando nas outras rotas. Não aceita `Idempotency-Key` e
  não repete.
  """
  @spec validate_signature(String.t(), keyword()) ::
          {:ok, signature_check()} | {:error, Error.t()}
  def validate_signature(message, opts \\ []) when is_binary(message) do
    with {:ok, body} <-
           post(
             @signature_validate_path,
             %{"RAW_BODY" => message},
             Keyword.merge(opts, sign: true, retry: false)
           ) do
      {:ok,
       %{
         message: Map.get(body, "message"),
         request_body: Map.get(body, "request_body"),
         status: Map.get(body, "status")
       }}
    end
  end

  @doc """
  Envia a requisição e normaliza o resultado.

  Todo 2xx é sucesso. A Iugu responde 200 até em criação, então o status não
  carrega significado para quem chama; o corpo decodificado basta.
  """
  @spec request(atom(), String.t(), keyword()) :: {:ok, term()} | {:error, Error.t()}
  def request(method, path, opts \\ []) do
    with {:ok, %Req.Response{body: body}} <- request_raw(method, path, opts) do
      {:ok, body}
    end
  end

  @doc """
  Como `request/3`, mas devolve a resposta inteira.

  Serve para quem precisa dos headers ou do status cru, o que nenhuma rota
  documentada da Iugu exige hoje.
  """
  @spec request_raw(atom(), String.t(), keyword()) ::
          {:ok, Req.Response.t()} | {:error, Error.t()}
  def request_raw(method, path, opts \\ []) do
    {client_opts, opts} = Keyword.split(opts, @client_options)
    {signature_opts, req_opts} = Keyword.split(opts, @signature_options)

    api_token = Keyword.get(client_opts, :api_token) || Config.api_token!()

    client_opts
    |> Keyword.put(:api_token, api_token)
    |> new()
    |> attach_signature(api_token, signature_opts)
    |> Req.request([method: method, url: path] ++ req_opts)
    |> normalize(path)
  end

  @doc """
  Escapa um segmento de caminho.

  Os ids da Iugu são hexadecimais e não precisam disso, mas `order_id` e
  chaves Pix de e-mail entram na URL das buscas por id externo, e `@` ou `+`
  sem escape mudam a rota.
  """
  @spec encode_path_segment(String.t()) :: String.t()
  def encode_path_segment(value) when is_binary(value) do
    URI.encode(value, &URI.char_unreserved?/1)
  end

  defp authorization_header(:none), do: []
  defp authorization_header(api_token), do: [authorization: basic_authorization(api_token)]

  defp basic_authorization(api_token) do
    "Basic " <> Base.encode64(api_token <> ":")
  end

  defp attach_signature(request, api_token, signature_opts) do
    if Keyword.get(signature_opts, :sign, false) do
      if api_token == :none do
        raise ArgumentError,
              "uma requisição assinada precisa de um api_token: ele é a segunda linha da string assinada."
      end

      private_key =
        Keyword.get(signature_opts, :signature_private_key) || Config.signature_private_key!()

      token_id = Keyword.get(signature_opts, :signature_token_id) || Config.signature_token_id()

      Req.Request.append_request_steps(request,
        iugu_signature: &sign_request(&1, api_token, private_key, token_id)
      )
    else
      request
    end
  end

  # Roda depois dos passos do próprio Req, então o corpo já está codificado e a
  # URL já carrega base_url e params. O caminho assinado é o sem a query string,
  # que é o que as receitas da Iugu fazem.
  defp sign_request(request, api_token, private_key, token_id) do
    body = signed_body(request.body)

    headers =
      Signature.headers(
        request.method |> Atom.to_string() |> String.upcase(),
        request.url.path,
        body,
        api_token: api_token,
        private_key: private_key,
        token_id: token_id,
        request_time: DateTime.utc_now()
      )

    request
    |> put_signed_body(body)
    |> put_api_token_param(api_token)
    |> Req.Request.put_headers(headers)
  end

  defp signed_body(nil), do: ""
  defp signed_body(body), do: IO.iodata_to_binary(body)

  # Requisição sem corpo continua sem corpo; só um corpo codificado é trocado
  # pelo binário exato que entrou na assinatura.
  defp put_signed_body(request, ""), do: request
  defp put_signed_body(request, body), do: %{request | body: body}

  defp put_api_token_param(request, api_token) do
    update_in(request.url.query, fn query ->
      (query || "")
      |> URI.decode_query()
      |> Map.put("api_token", api_token)
      |> URI.encode_query()
    end)
  end

  defp normalize({:ok, %Req.Response{status: status} = response}, _path)
       when status in 200..299 do
    {:ok, response}
  end

  defp normalize({:ok, %Req.Response{} = response}, path) do
    {:error, Error.from_response(response, path)}
  end

  defp normalize({:error, exception}, path) do
    {:error, Error.from_exception(exception, path)}
  end
end
