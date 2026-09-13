defmodule Iugu.Transfer do
  @moduledoc """
  Transferência entre contas Iugu: de subconta para a mestre, da mestre para
  uma subconta ou entre subcontas.

  É o mecanismo dos marketplaces: "Essa transferência pode ser feita de
  subconta para outras subcontas e/ou para a conta mestre e pode ser feita da
  conta mestre para as subcontas." Só existe por API, o mínimo é 1 centavo e
  a Iugu cobra tarifa por transferência ("Transferências entre contas iugu
  são tarifadas, portanto, atente-se em deduzir também esta tarifa"). A
  receita oficial de "cobrar tarifa de saque da subconta" é exatamente esta
  rota: a subconta saca com `Iugu.Account.request_withdraw/3` e
  em seguida transfere a tarifa para a mestre.

  Para mandar dinheiro a uma conta bancária que **não** é Iugu (Pix ou TED
  para terceiros), veja `Iugu.TransferRequest`. A rota recusa uma
  conta Iugu como destino ("Can't create a transfer request to iugu. Use the
  'Transfer between iugu accounts' feature for this.").

  ## Token: o da conta que paga

  `create/3` autentica com o `live_api_token` da conta **pagadora**, a que
  tem o saldo debitado: a subconta usa o dela para pagar a mestre; a mestre
  usa o padrão do SDK para pagar uma subconta. A rota "está configurada para
  operar exclusivamente em ambiente de produção (live_mode)", então o
  `test_api_token` não serve. `list/1` aceita `live_api_token` ou
  `test_api_token`, da subconta ou da mestre, e lista o que **aquela** conta
  enviou e recebeu.

  ## Assinatura RSA no fluxo whitelabel

  `POST /v1/transfers` está na tabela de rotas com assinatura obrigatória. A
  chave pública fica registrada uma vez, na conta mestre; o SDK assina com a
  chave privada da mestre (`Iugu.Config.signature_private_key!/0`)
  e coloca o `live_api_token` da pagadora na segunda linha do documento e na
  requisição. Chave ausente na mestre responde 422 `Public Key Not Found`;
  relógio fora dos cinco minutos de tolerância, `Invalid Elapsed Time`.

  ## Idempotência e retry

  Esta é uma das duas rotas de cash out que aceitam `Idempotency-Key` (a
  outra é a transferência para terceiros). "Se várias requisições forem
  enviadas com a mesma chave de idempotência no mesmo instante, apenas uma
  será processada com sucesso. Para as demais, será retornado o erro 409
  (Conflito)", que o SDK devolve como `kind: :validation, status: 409`. Com
  a opção `:idempotency_key`, `create/3` liga o retry (`:transient`); sem
  ela **nunca repete**, mesmo com `retry:` na opção, porque um timeout pode
  ter debitado a pagadora e a segunda tentativa debitaria de novo.

  ## A transferência é síncrona

  A resposta 200 não traz `status`: o valor já mudou de conta, e o extrato
  (`Iugu.FinancialStatement.financial/1`) mostra a movimentação com
  `reference_type: "Transfer"` e o mesmo `id`. Os webhooks `transfer.debited`
  (na pagadora) e `transfer.credited` (na recebedora) confirmam depois. Não
  há `GET /v1/transfers/{id}` documentado; uma transferência se localiza em
  `list/1` ou no extrato.

  ## Erros de validação vêm em `message`, não em `errors`

  Diferente do resto da API, o 422 desta rota usa o envelope
  `{"message": {"campo": ["mensagem"]}}`: `receiver_account_id` em branco,
  `amount_cents` não numérico, `amount_cents: Saldo insuficiente`,
  `receiver_account: não encontrado`. O `Iugu.Error` lê esse mapa
  como o de `errors`, então `messages` e `fields` chegam preenchidos e
  `"Saldo insuficiente"` se distingue sem abrir `body`.

  ## O que não está confirmado

    * se `limit` em `list/1` vale para `sent` e `received` juntos ou para cada
      lista; por isso não há `stream/1` aqui, e o chamador pagina com
      `:start` conferindo as duas listas
    * qual campo `created_at_from`/`created_at_to` filtram de fato (o texto
      da documentação fala em `updated_at` e mostra data com hora e fuso; o
      esquema declara `date`); o SDK manda `DateTime` no fuso de São Paulo e
      `Date` em `AAAA-MM-DD`
    * o corpo do 409 de chave repetida e o TTL da chave
    * o valor da tarifa por transferência, que depende do plano da conta
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Pagination
  alias Iugu.Params
  alias Iugu.Response

  @path "/v1/transfers"
  @max_limit 100
  @minimum_amount_cents 1
  @transfer_types ["account_requested", "internal_transfer", "mirror", "debit_transfer"]
  @datetime_filters [:created_at_from, :created_at_to]
  @list_filters [
                  :start,
                  :limit,
                  :custom_variables_name,
                  :custom_variables_value,
                  :transfer_type
                ] ++ @datetime_filters

  @type party :: %{id: String.t() | nil, name: String.t() | nil}

  @type t :: %{
          id: String.t() | nil,
          amount_cents: integer() | nil,
          amount_localized: String.t() | nil,
          sender: party() | nil,
          receiver: party() | nil,
          custom_variables: [map()],
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          body: map()
        }

  @type page :: %{sent: [t()], received: [t()], page_info: Pagination.page_info()}

  @doc """
  Transfere `amount_cents` da conta que autentica para a conta `receiver_id`.
  Veja o moduledoc.

  Requisição assinada, autenticada com o `live_api_token` da conta pagadora
  em `api_token:` (a mestre usa o padrão do SDK). Abaixo de 1 centavo devolve
  erro de validação sem ir à Iugu. Opções: `:custom_variables` (lista de
  `%{name, value}`, filtrável depois em `list/1`) e `:idempotency_key` (vira
  o header e liga o retry; sem ela a chamada nunca repete).

  A resposta normalizada traz `id`, `amount_cents`, `amount_localized`,
  `sender`, `receiver`, `custom_variables`, `created_at`, `updated_at` e o
  corpo cru em `body`.
  """
  @spec create(String.t(), pos_integer(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(receiver_id, amount_cents, opts \\ [])
      when is_binary(receiver_id) and is_integer(amount_cents) do
    {create_opts, req_opts} = Keyword.split(opts, [:custom_variables, :idempotency_key])

    with :ok <- validate_receiver(receiver_id),
         :ok <- validate_amount(amount_cents) do
      body =
        Params.put_present(
          %{"receiver_id" => receiver_id, "amount_cents" => amount_cents},
          "custom_variables",
          Keyword.get(create_opts, :custom_variables)
        )

      req_opts =
        req_opts
        |> Keyword.put(:sign, true)
        |> Client.idempotency_options(Keyword.get(create_opts, :idempotency_key))

      with {:ok, response} <- Client.post(@path, body, req_opts) do
        {:ok, normalize(response)}
      end
    end
  end

  @doc """
  Transferências enviadas e recebidas pela conta que autentica.

  `GET /v1/transfers`, `live_api_token` ou `test_api_token`, mestre ou
  subconta. Filtros: `:start`, `:limit` (preso a 100, que também é o padrão
  da rota), `:custom_variables_name`, `:custom_variables_value`,
  `:created_at_from`, `:created_at_to` (`DateTime`, convertido para o horário
  de São Paulo; `Date`; ou string já no formato da Iugu) e `:transfer_type`
  (um de `transfer_types/0`).

  A resposta tem duas listas, `sent` e `received`, e nenhum total: a Iugu
  escreve `amount_cents` como string nesta rota (`"1000"`), e o SDK devolve
  inteiro. Veja o moduledoc sobre `limit` e paginação.
  """
  @spec list(keyword()) :: {:ok, page()} | {:error, Error.t()}
  def list(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, @list_filters)

    with :ok <- validate_transfer_type(Keyword.get(filter_opts, :transfer_type)),
         params = list_params(filter_opts),
         {:ok, body} <- Client.get(@path, Keyword.put(req_opts, :params, params)) do
      {:ok,
       %{
         sent: body |> Response.items(["sent"]) |> Enum.map(&normalize/1),
         received: body |> Response.items(["received"]) |> Enum.map(&normalize/1),
         page_info:
           Pagination.page_info(body,
             start: Map.get(params, :start, 0),
             limit: Map.get(params, :limit)
           )
       }}
    end
  end

  @doc "Tipos de transferência aceitos no filtro `transfer_type` de `list/1`."
  @spec transfer_types() :: [String.t()]
  def transfer_types, do: @transfer_types

  defp normalize(body) when is_map(body) do
    %{
      id: Map.get(body, "id"),
      amount_cents: Response.integer(body, ["amount_cents"]),
      amount_localized: Map.get(body, "amount_localized"),
      sender: normalize_party(Map.get(body, "sender")),
      receiver: normalize_party(Map.get(body, "receiver")),
      custom_variables: Response.items(body, ["custom_variables"]),
      created_at: Map.get(body, "created_at"),
      updated_at: Map.get(body, "updated_at"),
      body: body
    }
  end

  defp normalize_party(%{} = party), do: %{id: Map.get(party, "id"), name: Map.get(party, "name")}
  defp normalize_party(_party), do: nil

  defp validate_receiver(""), do: {:error, Error.validation("receiver_id é obrigatório.", @path)}
  defp validate_receiver(_receiver_id), do: :ok

  defp validate_amount(amount_cents) when amount_cents >= @minimum_amount_cents, do: :ok

  defp validate_amount(_amount_cents) do
    {:error, Error.validation("A transferência mínima é de 1 centavo.", @path)}
  end

  defp validate_transfer_type(nil), do: :ok
  defp validate_transfer_type(type) when type in @transfer_types, do: :ok

  defp validate_transfer_type(type) do
    {:error,
     Error.validation(
       "transfer_type inválido: #{inspect(type)}. Use um de #{inspect(@transfer_types)}.",
       @path
     )}
  end

  defp list_params(filter_opts) do
    params =
      filter_opts
      |> Pagination.params(@max_limit)
      |> Params.put_present(
        :custom_variables_name,
        Keyword.get(filter_opts, :custom_variables_name)
      )
      |> Params.put_present(
        :custom_variables_value,
        Keyword.get(filter_opts, :custom_variables_value)
      )
      |> Params.put_present(:transfer_type, Keyword.get(filter_opts, :transfer_type))

    Enum.reduce(@datetime_filters, params, fn filter, params ->
      Params.put_present(
        params,
        filter,
        filter_opts |> Keyword.get(filter) |> Params.format_local_datetime()
      )
    end)
  end
end
