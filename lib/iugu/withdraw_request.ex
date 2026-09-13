defmodule Iugu.WithdrawRequest do
  @moduledoc """
  Saques: o que acontece com um pedido de saque depois de criado.

  "A transferência bancária, mais comumente chamada de saque, é a retirada de
  valores da conta iugu para uma conta bancária de mesmo titular." O pedido
  em si é `Iugu.Account.request_withdraw/3` (assinado, em reais,
  mínimo de R$ 5,00, sem retry); este módulo acompanha o pedido: consulta,
  listagem por conta e a conciliação que a conta mestre faz sobre todas as
  subcontas. Nenhuma rota aqui exige assinatura RSA.

  ## Ciclo de vida

  Depois do pedido "o dinheiro passa para o campo 'Em Trânsito'", e a
  liquidação é "em D+1, ou seja, no dia útil seguinte da solicitação":
  pedido na sexta cai na segunda. O webhook `withdraw_request.status_changed`
  "será disparada no dia seguinte a compensação em seu domicílio bancário".

  Os status documentados, entre referência e webhooks: `pending` (criado),
  `processing`, `accepted`, `rejected`, `inconsistent`, `refunded`,
  `partially_refunded` e `reprocessing`. `accepted` não é garantia de
  desfecho: o webhook traz `rejected_after_accepted: true` quando o banco
  devolve uma transferência já aceita, e `feedback` guarda o motivo da recusa
  (`Código: '2' - Agência ou Conta Destinatária do Crédito Inválida`; nos
  webhooks, códigos como `CH11`). As transições além de
  `pending → processing → accepted | rejected` **não estão documentadas**.

  ## Dinheiro vem como texto, em duas formas

  `get/2` e `list/1` escrevem `amount` em pt-BR (`"R$ 10,00"`); a
  conciliação escreve decimal em reais (`"4500.0"`). O mapa normalizado traz
  `amount_cents` inteiro nos dois casos, lendo com
  `Iugu.Money.parse_brl/1` e depois `parse_reais/1`; uma forma nova
  vira `nil`, nunca zero.

  ## Qual token

    * `get/2` e `list/1`: `live_api_token` ou `test_api_token` da conta dona
      do pedido (subconta ou mestre), em `api_token:`. Se a mestre enxerga os
      saques das subcontas em `list/1` **não está documentado**; para isso
      existe a conciliação
    * `conciliation/1`: `live_api_token` da conta **mestre** (o padrão do
      SDK): "No caso de marketplaces ou parceiros de negócios, retorna também
      os pedidos de saques de subcontas". Só cobre produção (LIVE)

  ## O que não está confirmado

    * se `GET /v1/withdraw_requests` aceita `start` e `limit` (a rota não os
      documenta; `list/1` os repassa quando informados)
    * se `GET /v1/withdraw_requests/{id}` traz `paying_at`, `custom_variables`,
      `receipt_url` e `agreement_effect` como a listagem, e a forma do 404
    * se `GET /v1/withdraw_conciliations` exige assinatura RSA (a página da
      rota não declara os headers; um aviso solto na tabela de erros sugere
      que sim); o SDK não assina, e um 422 `Public Key Not Found` ali é o
      sinal para passar `sign: true`
    * o máximo de `limit` na conciliação (padrão 100; o SDK prende a 100)
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Money
  alias Iugu.Pagination
  alias Iugu.Params
  alias Iugu.Response

  @path "/v1/withdraw_requests"
  @conciliation_path "/v1/withdraw_conciliations"
  @max_limit 100
  @statuses [
    "pending",
    "processing",
    "accepted",
    "rejected",
    "inconsistent",
    "refunded",
    "partially_refunded",
    "reprocessing"
  ]
  @conciliation_statuses ["pending", "processing", "accepted", "rejected"]
  @list_filters [:start, :limit, :status, :custom_variables_name, :custom_variables_value]
  @conciliation_datetime_filters [:from, :to]
  @conciliation_filters [:start, :limit, :status] ++ @conciliation_datetime_filters

  @type t :: %{
          id: String.t() | nil,
          status: String.t() | nil,
          amount_cents: integer() | nil,
          feedback: String.t() | nil,
          reference: String.t() | nil,
          account_id: String.t() | nil,
          account_name: String.t() | nil,
          paying_at: String.t() | nil,
          receipt_url: String.t() | nil,
          agreement_effect: boolean(),
          bank_address: map() | nil,
          custom_variables: [map()],
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          body: map()
        }

  @type page :: %{withdraw_requests: [t()], page_info: Pagination.page_info()}

  @doc """
  Um pedido de saque pelo id devolvido por `request_withdraw/3` ou pelo
  `data[withdraw_request_id]` do webhook.

  Autenticada com o token da conta dona do pedido em `api_token:`. Sem
  assinatura. `bank_address` vem como a Iugu escreve, com `account_type`
  por extenso (`Corrente`, `Poupança`, `Pagamento`).
  """
  @spec get(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def get(withdraw_request_id, opts \\ []) when is_binary(withdraw_request_id) do
    with {:ok, body} <- Client.get(item_path(withdraw_request_id), opts) do
      {:ok, normalize(body)}
    end
  end

  @doc """
  Saques da conta que autentica.

  `GET /v1/withdraw_requests`, token da conta em `api_token:`. Filtros:
  `:status` (um de `statuses/0`), `:custom_variables_name` e
  `:custom_variables_value` (as variáveis enviadas no pedido), `:start` e
  `:limit` (repassados; veja o moduledoc). `agreement_effect` diz se o valor
  veio de antecipação de recebíveis.
  """
  @spec list(keyword()) :: {:ok, page()} | {:error, Error.t()}
  def list(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, @list_filters)

    with :ok <- validate_status(Keyword.get(filter_opts, :status), @statuses, @path),
         params = list_params(filter_opts),
         {:ok, body} <- Client.get(@path, Keyword.put(req_opts, :params, params)) do
      {:ok, page(body, Response.items(body), params)}
    end
  end

  @doc """
  Conciliação de saques da conta mestre e de todas as subcontas.

  `GET /v1/withdraw_conciliations`, `live_api_token` da mestre (o padrão do
  SDK). Filtra por `:status` (`pending`, `processing`, `accepted`,
  `rejected`; padrão todos) e pela janela de **atualização** `:from` e `:to`
  (`DateTime`, convertido para o horário de São Paulo, ou string
  `AAAA-MM-DDThh:mm:ss-03:00`; padrão de um dia atrás até agora), mais
  `:start` e `:limit` (padrão e máximo 100). Data fora do ISO 8601 é 400
  `date: Formato de data inválido`.

  Cada item traz o `account_id` da conta que sacou, e o total vem em
  `total_items` (snake_case, ao contrário do resto da API).
  """
  @spec conciliation(keyword()) :: {:ok, page()} | {:error, Error.t()}
  def conciliation(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, @conciliation_filters)

    with :ok <-
           validate_status(
             Keyword.get(filter_opts, :status),
             @conciliation_statuses,
             @conciliation_path
           ),
         params = conciliation_params(filter_opts),
         {:ok, body} <- Client.get(@conciliation_path, Keyword.put(req_opts, :params, params)) do
      {:ok, page(body, Response.items(body, ["withdraw_requests"]), params)}
    end
  end

  @doc """
  Percorre todas as páginas de `conciliation/1` com os mesmos filtros.

  Para na primeira página menor que `limit` e levanta o
  `Iugu.Error` da primeira página que falhar.
  """
  @spec stream_conciliation(keyword()) :: Enumerable.t()
  def stream_conciliation(opts \\ []) do
    {page_opts, other_opts} = Keyword.split(opts, [:start, :limit])

    Pagination.stream(
      fn stream_page_opts ->
        with {:ok, page} <- conciliation(Keyword.merge(other_opts, stream_page_opts)) do
          {:ok, page.withdraw_requests}
        end
      end,
      ["items"],
      Keyword.put(page_opts, :max_limit, @max_limit)
    )
  end

  @doc "Os status de saque documentados, reunindo referência e webhooks."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Os status que o filtro da conciliação aceita."
  @spec conciliation_statuses() :: [String.t()]
  def conciliation_statuses, do: @conciliation_statuses

  defp page(body, items, params) do
    %{
      withdraw_requests: Enum.map(items, &normalize/1),
      page_info:
        Pagination.page_info(body,
          start: Map.get(params, :start, 0),
          limit: Map.get(params, :limit)
        )
    }
  end

  defp normalize(body) when is_map(body) do
    %{
      id: Map.get(body, "id"),
      status: Map.get(body, "status"),
      amount_cents: amount_cents(Map.get(body, "amount")),
      feedback: Map.get(body, "feedback"),
      reference: Map.get(body, "reference"),
      account_id: Map.get(body, "account_id"),
      account_name: Map.get(body, "account_name"),
      paying_at: Map.get(body, "paying_at"),
      receipt_url: Map.get(body, "receipt_url"),
      agreement_effect: Response.flag(body, "agreement_effect"),
      bank_address: Map.get(body, "bank_address"),
      custom_variables: Response.items(body, ["custom_variables"]),
      created_at: Map.get(body, "created_at"),
      updated_at: Map.get(body, "updated_at"),
      body: body
    }
  end

  # "R$ 10,00" nas rotas de solicitação, "4500.0" na conciliação; os dois são
  # reais, nunca centavos.
  defp amount_cents(amount) do
    with :error <- Money.parse_brl(amount),
         :error <- Money.parse_reais(amount) do
      nil
    else
      {:ok, cents} -> cents
    end
  end

  defp validate_status(nil, _allowed, _path), do: :ok

  defp validate_status(status, allowed, path) do
    if status in allowed do
      :ok
    else
      {:error,
       Error.validation(
         "status inválido: #{inspect(status)}. Use um de #{inspect(allowed)}.",
         path
       )}
    end
  end

  defp list_params(filter_opts) do
    filter_opts
    |> Pagination.params(@max_limit)
    |> Params.put_present(:status, Keyword.get(filter_opts, :status))
    |> Params.put_present(
      :custom_variables_name,
      Keyword.get(filter_opts, :custom_variables_name)
    )
    |> Params.put_present(
      :custom_variables_value,
      Keyword.get(filter_opts, :custom_variables_value)
    )
  end

  defp conciliation_params(filter_opts) do
    params =
      filter_opts
      |> Pagination.params(@max_limit)
      |> Params.put_present(:status, Keyword.get(filter_opts, :status))

    Enum.reduce(@conciliation_datetime_filters, params, fn filter, params ->
      Params.put_present(
        params,
        filter,
        filter_opts |> Keyword.get(filter) |> Params.format_local_datetime()
      )
    end)
  end

  defp item_path(withdraw_request_id),
    do: "#{@path}/#{Client.encode_path_segment(withdraw_request_id)}"
end
