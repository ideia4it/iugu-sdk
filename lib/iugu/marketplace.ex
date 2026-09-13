defmodule Iugu.Marketplace do
  @moduledoc """
  Marketplace: o que a conta mestre faz com as subcontas.

  A conta mestre cria as subcontas, lista, desativa e administra os tokens de
  API delas. Tudo que acontece **dentro** de uma subconta (verificação KYC,
  saldo, configuração, domicílio bancário, saque) fica em
  `Iugu.Account`.

  ## Só existe em produção

  "A criação de subcontas funciona apenas no ambiente de PRODUÇÃO." Não há
  sandbox para o ciclo de vida do marketplace, e a assinatura RSA que
  `create_account/2` exige também só vale em `live_mode`. Com o
  `test_api_token` estas rotas respondem 401 ou 422.

  ## Tokens

  `create_account/2`, `list_accounts/1`, `stream_accounts/1` e
  `deactivate_account/2` usam o `live_api_token` da conta mestre, que é o
  token padrão do SDK (`Iugu.Config.api_token!/0`). A documentação
  não diz qual token lista as subcontas; como a rota lista "as contas de um
  marketplace", só pode ser o da mestre.

  As rotas de tokens de API (`create_api_token/4`, `list_api_tokens/2`,
  `delete_api_token/3`) exigem o `master_token`, um token de tipo "Mestre"
  criado no painel Alia e diferente do `live_api_token`. Ele não fica na
  configuração porque serve só a essas três rotas; passe `api_token: master_token`
  em cada chamada.

  ## Os tokens da subconta aparecem uma vez só

  A resposta de `create_account/2` é o único lugar em que `live_api_token`,
  `test_api_token` e `user_token` aparecem por inteiro: "Esses dados são
  exibidos apenas neste retorno." Quem chama guarda os três, cifrados. Depois
  disso `list_api_tokens/2` só devolve versões mascaradas (seis caracteres e
  asteriscos), e `create_api_token/4` gera tokens novos, não recupera os
  antigos.

  ## O nome da subconta vira chave Pix

  "No parâmetro `name` não conter caracteres especiais ou números, pois haverá
  impacto na habilitação do pix junto a bacen." A Iugu aceita o nome e o Pix
  da subconta falha depois, no Banco Central, sem aviso. Por isso
  `create_account/2` recusa aqui, antes da chamada, um nome com dígito ou
  símbolo. Renomear depois só com o suporte.

  ## Uma criação por vez

  A Iugu processa uma criação de subconta por vez por conta mestre e responde
  400 `"Apenas uma criação de subconta pode ser processada por vez. Por favor,
  tente novamente em breve."` para a segunda. `creation_in_progress?/1`
  reconhece esse erro para quem serializa as criações numa fila e tenta de
  novo. Fora esse caso, `create_account/2` **nunca repete**: a rota não aceita
  chave de idempotência e cada chamada que chega cria uma subconta nova, com
  custo de manutenção.

  ## Subconta não se apaga

  "Subcontas NÃO podem ser excluídas." `deactivate_account/2` é o mais perto:
  cancela faturas, assinaturas e carnês pendentes, deixa a conta `unverified`
  e é irreversível. A conta precisa estar com saldo zero; a documentação não
  mostra a mensagem do 400 quando não está. A desativação é assíncrona: o 200
  diz "em processo de desativação", e o fim se confirma por
  `Iugu.Account.get/2` (`verified?: false`) ou por `list_accounts/1`.
  Não há webhook documentado para isso.

  ## Splits padrão

  `:splits` em `create_account/2` define os splits aplicados a **toda** fatura
  que a subconta receber. As regras da Iugu: nunca incluir a própria conta
  criadora, nunca somar 100% da fatura (o split é ignorado em silêncio e a
  criadora recebe tudo), `cents` e `percent` juntos só com
  `permit_aggregated: true`, destinatários do mesmo marketplace e sem
  repetição. O mapa vai no formato da API (`recipient_account_id`, `cents`,
  `percent`, `pix_cents`, `credit_card_1x_cents`...), e os valores em
  centavos são inteiros mesmo onde a receita oficial mostra string.

  ## O que não está confirmado

    * `totalItems` em `list_accounts/1`: outras listagens da Iugu passaram a
      devolver o tamanho da página nesse campo; `stream_accounts/1` para
      quando a página volta menor que `limit` e não olha para ele
    * se o `DELETE` de token valida de fato os headers RSA: o OpenAPI os
      declara obrigatórios, a tabela de rotas obrigatórias não o lista; o SDK
      assina
    * os demais valores de `live_token_status`/`test_token_status` além de
      `active` (um token pendente de aprovação deve aparecer aqui)
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Pagination
  alias Iugu.Params
  alias Iugu.Response

  @create_account_path "/v1/marketplace/create_account"
  @deactivate_path "/v1/marketplace/deactivate"
  @list_path "/v1/marketplace"
  @max_limit 1_000
  @api_types ["LIVE", "TEST"]
  @creation_in_progress_message "Apenas uma criação de subconta pode ser processada por vez"

  # Só letras (com acento) e espaços: qualquer outra coisa quebra a criação da
  # chave Pix EVP no Banco Central lá na frente, não a chamada em si.
  @name_pattern ~r/\A[\p{L} ]+\z/u

  @type created_account :: %{
          account_id: String.t(),
          name: String.t() | nil,
          live_api_token: String.t(),
          test_api_token: String.t(),
          user_token: String.t(),
          body: map()
        }

  @doc """
  Cria uma subconta e devolve os três tokens dela.

  Requisição assinada com a chave RSA da conta mestre e autenticada com o
  `live_api_token` da mestre (o padrão). Opções além das do
  `Iugu.Client`:

    * `:splits`: lista de splits padrão, no formato da API (veja o moduledoc)

  O nome só pode ter letras e espaços; qualquer outra coisa devolve
  `{:error, %Iugu.Error{kind: :validation, status: nil}}` sem ir à
  Iugu. Uma resposta 200 sem os três tokens vira `kind: :unexpected`, porque
  seguir sem eles deixaria a subconta inacessível para sempre.
  """
  @spec create_account(String.t(), keyword()) :: {:ok, created_account()} | {:error, Error.t()}
  def create_account(name, opts \\ []) when is_binary(name) do
    {body_opts, req_opts} = Keyword.split(opts, [:splits])

    with :ok <- validate_name(name),
         {:ok, body} <-
           Client.post(
             @create_account_path,
             Params.put_present(%{"name" => name}, "splits", Keyword.get(body_opts, :splits)),
             Keyword.merge(req_opts, sign: true, retry: false)
           ) do
      extract_tokens(body)
    end
  end

  @doc """
  Se o erro é o 400 de "uma criação de subconta por vez".

  É o único erro de `create_account/2` que vale repetir: a criação anterior
  ainda está em andamento e a Iugu pede para tentar em breve.
  """
  @spec creation_in_progress?(Error.t()) :: boolean()
  def creation_in_progress?(%Error{status: 400, messages: messages}) do
    Enum.any?(messages, &String.contains?(&1, @creation_in_progress_message))
  end

  def creation_in_progress?(_error), do: false

  @doc """
  Lista as subcontas do marketplace, com `id`, `name` e `verified`.

  Opções: `:start`, `:limit` (padrão 100, máximo 1.000) e `:query` (busca
  textual). A lista não traz token nem saldo; para isso é
  `Iugu.Account.get/2` por conta.
  """
  @spec list_accounts(keyword()) ::
          {:ok, %{accounts: [map()], page_info: Pagination.page_info()}} | {:error, Error.t()}
  def list_accounts(opts \\ []) do
    {page_opts, req_opts} = Keyword.split(opts, [:start, :limit, :query])
    params = list_params(page_opts)

    # page_info informa o limite que de fato saiu, que pode ser o teto da rota
    # em vez do que quem chamou pediu.
    with {:ok, body} <- Client.get(@list_path, Keyword.put(req_opts, :params, params)) do
      {:ok,
       %{
         accounts: Response.items(body),
         page_info: Pagination.page_info(body, Map.to_list(params))
       }}
    end
  end

  @doc """
  Todas as subcontas, seguindo a paginação.

  Aceita as mesmas opções de `list_accounts/1`. Levanta `Iugu.Error`
  se alguma página falhar, para que a falha não vire uma lista curta
  silenciosa.
  """
  @spec stream_accounts(keyword()) :: Enumerable.t()
  def stream_accounts(opts \\ []) do
    {page_opts, req_opts} = Keyword.split(opts, [:start, :limit, :query])
    query = Keyword.take(page_opts, [:query])

    Pagination.stream(
      fn stream_page_opts -> fetch_page(Keyword.merge(query, stream_page_opts), req_opts) end,
      ["items"],
      Keyword.put(page_opts, :max_limit, @max_limit)
    )
  end

  @doc """
  Desativa uma subconta. Irreversível; veja o moduledoc.

  Autenticada com o `live_api_token` da conta mestre, sem assinatura. A
  resposta é `%{"success" => true, "message" => "A conta está em processo de
  desativação..."}`: o efeito é assíncrono.
  """
  @spec deactivate_account(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def deactivate_account(account_id, opts \\ []) when is_binary(account_id) do
    Client.post(@deactivate_path, %{"account_id" => account_id}, Keyword.put(opts, :retry, false))
  end

  @doc """
  Cria um `api_token` novo numa subconta.

  Exige o `master_token` da conta mestre em `api_token:` e a assinatura RSA.
  `api_type` é `"LIVE"` ou `"TEST"`; outro valor volta como erro de
  validação (`status: nil`) aqui em vez de virar 400 lá. A resposta traz o
  `token` por inteiro, e é a única vez que ele aparece.
  """
  @spec create_api_token(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_api_token(account_id, api_type, description, opts \\ [])
      when is_binary(account_id) and is_binary(description) do
    path = api_tokens_path(account_id)

    with :ok <- Params.validate_member(api_type, @api_types, "api_type", path) do
      Client.post(
        path,
        %{"api_type" => api_type, "description" => description},
        Keyword.merge(opts, sign: true, retry: false)
      )
    end
  end

  @doc """
  Lista os tokens das subcontas, mascarados.

  Exige o `master_token` em `api_token:` e a assinatura RSA, num GET sem
  corpo (a terceira linha do documento assinado fica vazia; veja
  `Iugu.Signature`). A resposta é
  `%{"referrer_id" => id_da_mestre, "accounts" => %{account_id => %{"live_token" => "B2C614****...", ...}}}`.
  """
  @spec list_api_tokens(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_api_tokens(account_id, opts \\ []) when is_binary(account_id) do
    Client.get(api_tokens_path(account_id), Keyword.put(opts, :sign, true))
  end

  @doc """
  Remove um `api_token` de uma subconta.

  Exige o `master_token` em `api_token:`. O OpenAPI declara os headers de
  assinatura como obrigatórios, então o SDK assina; devolve o token removido.
  """
  @spec delete_api_token(String.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def delete_api_token(account_id, token_id, opts \\ [])
      when is_binary(account_id) and is_binary(token_id) do
    Client.delete(
      "#{api_tokens_path(account_id)}/#{Client.encode_path_segment(token_id)}",
      Keyword.merge(opts, sign: true, retry: false)
    )
  end

  @doc "Tipos de token aceitos por `create_api_token/4`."
  @spec api_types() :: [String.t()]
  def api_types, do: @api_types

  defp fetch_page(page_opts, req_opts) do
    Client.get(@list_path, Keyword.put(req_opts, :params, list_params(page_opts)))
  end

  defp list_params(page_opts) do
    page_opts
    |> Pagination.params(@max_limit)
    |> Params.put_present(:query, Keyword.get(page_opts, :query))
  end

  defp validate_name(name) do
    if Regex.match?(@name_pattern, name) do
      :ok
    else
      {:error,
       Error.validation(
         "O nome da subconta só pode ter letras e espaços; dígitos e símbolos impedem a chave Pix no Banco Central.",
         @create_account_path
       )}
    end
  end

  defp extract_tokens(
         %{
           "account_id" => account_id,
           "live_api_token" => live_api_token,
           "test_api_token" => test_api_token,
           "user_token" => user_token
         } = body
       )
       when is_binary(account_id) and is_binary(live_api_token) and is_binary(test_api_token) and
              is_binary(user_token) do
    {:ok,
     %{
       account_id: account_id,
       name: Map.get(body, "name"),
       live_api_token: live_api_token,
       test_api_token: test_api_token,
       user_token: user_token,
       body: body
     }}
  end

  defp extract_tokens(body) do
    {:error,
     %Error{
       kind: :unexpected,
       path: @create_account_path,
       body: body,
       messages: ["resposta sem account_id, live_api_token, test_api_token e user_token"]
     }}
  end

  defp api_tokens_path(account_id), do: "/v1/#{Client.encode_path_segment(account_id)}/api_tokens"
end
