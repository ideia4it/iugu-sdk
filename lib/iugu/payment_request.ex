defmodule Iugu.PaymentRequest do
  @moduledoc """
  Pedido de pagamento: pagar um boleto com o saldo da conta Iugu.

  A Iugu chama o recurso de `payment_request` e é o nome dos webhooks
  (`payment_request.created`, `payment_request.status_changed`). É a ponta
  "conta digital" do BaaS: a subconta paga uma conta de luz ou um fornecedor
  direto do saldo, sem sacar antes. O dinheiro sai da conta que autentica.

  ## Validar antes, pagar em até 15 minutos

  "Antes de executar essa chamada, é necessário validar o pagamento" em
  `validate_barcode/2`, que confere a linha digitável na CIP e devolve o
  valor, a multa, os juros e o vencimento; "após a validação terá o período
  de 15 minutos para criar o pedido de pagamento". A validação sempre vai
  com `detailed: true`, porque é o que faz a Iugu preencher `details`, onde
  ela diz se o boleto "está em aberto ou baixado na CIP/Nuclea" ("Retorno
  CIP 01 Boleto já baixado" para pago, cancelado ou expirado). Um boleto
  válido e baixado ainda é `{:ok, _}`: quem paga lê `payment_info.details`.

  Quais boletos a Iugu paga está numa planilha de convênios fora da
  documentação (link na referência); um convênio fora dela falha na
  validação.

  ## Token, assinatura e idempotência

  `create/2` autentica com o `live_api_token` da conta pagadora (subconta ou
  mestre) e exige a assinatura RSA, como toda rota que move dinheiro; no
  fluxo whitelabel a chave é a da mestre e o token, o da subconta. A rota
  **não documenta `Idempotency-Key`**, então `create/2` nunca repete: um
  timeout pode ter pago o boleto, e a repetição pagaria de novo. Quem
  precisa saber o desfecho lista por `barcode` em `list/1`.

  As outras três rotas (`validate_barcode/2`, `get/2`, `list/1`) aceitam
  `live_api_token` ou `test_api_token`, sem assinatura.

  ## Valor do boleto e valor pago

  `document_amount_cents` é o valor de face do boleto e `amount_cents` o que
  se paga; divergem quando há multa e juros (`payment_info.total_amount_cents`
  da validação) ou quando o boleto permite valor diferente
  (`allow_amount_change`, `allow_partial_payment`). `create/2` só confere que
  os dois são inteiros positivos; a regra de quanto pode divergir é da Iugu.

  ## Ciclo de vida

  `pending` → `processing` → `done` ou `rejected`, com `rejected_at` e
  `error_message` no webhook de recusa. O 200 do pedido não é o pagamento;
  crie o gatilho `payment_request.status_changed` antes.

  ## O que não está confirmado

    * o envelope do 422 de `create/2` (saldo insuficiente, janela dos 15
      minutos vencida, convênio fora da lista) e se a validação expirada é
      400 ou 422
    * se `GET /v1/payment_requests` traz `totalItems` (o exemplo é uma lista
      crua, sem envelope) e se a mestre enxerga os pedidos das subcontas
    * se a rota de criação aceita `Idempotency-Key` sem documentar
    * os valores de `status` além dos quatro do filtro da listagem
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Pagination
  alias Iugu.Params
  alias Iugu.Response

  @path "/v1/payment_requests"
  @validate_path "/v1/payment_requests/validate"
  @max_limit 100
  @statuses ["pending", "processing", "rejected", "done"]
  @create_fields [:barcode, :amount_cents, :document_amount_cents, :description]
  @date_filters [:created_at_from, :created_at_to, :updated_at_from, :updated_at_to]
  @list_filters [:start, :limit, :status, :barcode] ++ @date_filters

  @type payment_info :: %{
          barcode: String.t() | nil,
          amount_cents: integer() | nil,
          fine_cents: integer() | nil,
          interest_cents: integer() | nil,
          discount_cents: integer() | nil,
          total_amount_cents: integer() | nil,
          due_date: String.t() | nil,
          maximum_payment_date: String.t() | nil,
          allow_amount_change: boolean(),
          allow_partial_payment: boolean(),
          recipient_name: String.t() | nil,
          recipient_cpf_cnpj: String.t() | nil,
          payer_name: String.t() | nil,
          payer_cpf_cnpj: String.t() | nil,
          payee_cpf_cnpj: String.t() | nil,
          emitter: String.t() | nil,
          details: String.t() | nil
        }

  @type validation :: %{
          message: String.t() | nil,
          payment_info: payment_info() | nil,
          body: map()
        }

  @type t :: %{
          id: String.t() | nil,
          account_id: String.t() | nil,
          barcode: String.t() | nil,
          status: String.t() | nil,
          amount_cents: integer() | nil,
          document_amount_cents: integer() | nil,
          description: String.t() | nil,
          receipt_url: String.t() | nil,
          payment_info: payment_info() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          body: map()
        }

  @type page :: %{payment_requests: [t()], page_info: Pagination.page_info()}

  @doc """
  Confere a linha digitável de um boleto na CIP e lê valor, encargos e
  vencimento. Veja o moduledoc sobre a janela de 15 minutos.

  `POST /v1/payment_requests/validate`, token da conta em `api_token:`, sem
  assinatura. Como não move dinheiro, repete em falha transitória. A
  resposta vem com `message` ("Boleto é válido") e `payment_info`
  normalizado, com os valores em centavos inteiros; um boleto que a Iugu não
  reconhece é `{:error, _}` com o status que ela devolver.
  """
  @spec validate_barcode(String.t(), keyword()) :: {:ok, validation()} | {:error, Error.t()}
  def validate_barcode(barcode, opts \\ []) when is_binary(barcode) do
    with :ok <- validate_barcode_present(barcode, @validate_path),
         {:ok, body} <-
           Client.post(
             @validate_path,
             %{"barcode" => barcode, "detailed" => true},
             Keyword.put_new(opts, :retry, :transient)
           ) do
      {:ok,
       %{
         message: Map.get(body, "message"),
         payment_info: payment_info(Map.get(body, "payment_info")),
         body: body
       }}
    end
  end

  @doc """
  Paga um boleto com o saldo da conta. Veja o moduledoc.

  Requisição assinada, autenticada com o `live_api_token` da conta pagadora
  em `api_token:`, **sem retry** (a rota não documenta `Idempotency-Key`).
  `attrs` leva `barcode`, `amount_cents`, `document_amount_cents` e
  `description`, em átomo ou string; o que a Iugu recusaria com 400 volta
  como `kind: :validation, status: nil` sem ir lá, e uma chave fora da lista
  levanta `ArgumentError`. A resposta vem normalizada como em `get/2`.
  """
  @spec create(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    body = build_create_body(attrs)

    with :ok <- validate_create(body),
         {:ok, response} <-
           Client.post(@path, body, Keyword.merge(opts, sign: true, retry: false)) do
      {:ok, normalize(response)}
    end
  end

  @doc """
  Um pedido de pagamento pelo id devolvido por `create/2` ou pelo
  `payment_request_id` do webhook, com o comprovante em `receipt_url`.

  Token da conta pagadora, sem assinatura. Id desconhecido é 404
  (`Payment request Not Found`).
  """
  @spec get(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def get(payment_request_id, opts \\ []) when is_binary(payment_request_id) do
    with {:ok, body} <- Client.get(item_path(payment_request_id), opts) do
      {:ok, normalize(body)}
    end
  end

  @doc """
  Pedidos de pagamento da conta que autentica, paginados.

  `GET /v1/payment_requests`, token da conta. Filtros: `:status` (um de
  `statuses/0`), `:barcode` (a forma de reencontrar um pedido depois de um
  timeout em `create/2`), `:created_at_from`, `:created_at_to`,
  `:updated_at_from` e `:updated_at_to` (`Date` ou string `AAAA-MM-DD`; a
  rota filtra por dia, não por hora), `:start` e `:limit` (preso a 100).
  """
  @spec list(keyword()) :: {:ok, page()} | {:error, Error.t()}
  def list(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, @list_filters)

    with :ok <-
           Params.validate_member(Keyword.get(filter_opts, :status), @statuses, "status", @path),
         params = list_params(filter_opts),
         {:ok, body} <- Client.get(@path, Keyword.put(req_opts, :params, params)) do
      {:ok,
       %{
         payment_requests: body |> Response.items() |> Enum.map(&normalize/1),
         page_info:
           Pagination.page_info(body,
             start: Map.get(params, :start, 0),
             limit: Map.get(params, :limit)
           )
       }}
    end
  end

  @doc """
  Percorre todas as páginas de `list/1` com os mesmos filtros.

  Para na primeira página menor que `limit` e levanta o
  `Iugu.Error` da primeira página que falhar.
  """
  @spec stream(keyword()) :: Enumerable.t()
  def stream(opts \\ []) do
    {page_opts, other_opts} = Keyword.split(opts, [:start, :limit])

    Pagination.stream(
      fn stream_page_opts ->
        with {:ok, page} <- list(Keyword.merge(other_opts, stream_page_opts)) do
          {:ok, page.payment_requests}
        end
      end,
      ["items"],
      Keyword.put(page_opts, :max_limit, @max_limit)
    )
  end

  @doc "Os status documentados de um pedido de pagamento."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  defp normalize(body) when is_map(body) do
    %{
      id: Response.get_any(body, ["id", "payment_request_id"]),
      account_id: Map.get(body, "account_id"),
      barcode: Map.get(body, "barcode"),
      status: Map.get(body, "status"),
      amount_cents: Response.integer(body, ["amount_cents"]),
      document_amount_cents: Response.integer(body, ["document_amount_cents"]),
      description: Map.get(body, "description"),
      receipt_url: Map.get(body, "receipt_url"),
      payment_info: payment_info(Map.get(body, "payment_info")),
      created_at: Map.get(body, "created_at"),
      updated_at: Map.get(body, "updated_at"),
      body: body
    }
  end

  defp payment_info(%{} = info) do
    %{
      barcode: Map.get(info, "barcode"),
      amount_cents: Response.integer(info, ["amount_cents"]),
      fine_cents: Response.integer(info, ["fine_cents"]),
      interest_cents: Response.integer(info, ["interest_cents"]),
      discount_cents: Response.integer(info, ["discount_cents"]),
      total_amount_cents: Response.integer(info, ["total_amount_cents"]),
      due_date: Map.get(info, "due_date"),
      maximum_payment_date: Map.get(info, "maximum_payment_date"),
      allow_amount_change: Response.flag(info, "allow_amount_change"),
      allow_partial_payment: Response.flag(info, "allow_partial_payment"),
      recipient_name: Map.get(info, "recipient_name"),
      recipient_cpf_cnpj: Map.get(info, "recipient_cnpj_cpf"),
      payer_name: Map.get(info, "payer_name"),
      payer_cpf_cnpj: Map.get(info, "payer_cnpj_cpf"),
      payee_cpf_cnpj: Map.get(info, "payee_cnpj_cpf"),
      emitter: Map.get(info, "emitter"),
      details: Map.get(info, "details")
    }
  end

  defp payment_info(_info), do: nil

  defp build_create_body(attrs) do
    Map.new(attrs, fn {key, value} ->
      {key |> Params.field!(@create_fields, "pedido de pagamento") |> Atom.to_string(), value}
    end)
  end

  defp validate_create(body) do
    with :ok <- validate_barcode_present(Map.get(body, "barcode"), @path),
         :ok <- validate_positive_cents(Map.get(body, "amount_cents"), "amount_cents") do
      validate_positive_cents(Map.get(body, "document_amount_cents"), "document_amount_cents")
    end
  end

  defp validate_barcode_present(barcode, _path) when is_binary(barcode) and barcode != "", do: :ok

  defp validate_barcode_present(_barcode, path),
    do: {:error, Error.validation("barcode é obrigatório.", path)}

  defp validate_positive_cents(cents, _field) when is_integer(cents) and cents > 0, do: :ok

  defp validate_positive_cents(_cents, field) do
    {:error, Error.validation("#{field} é obrigatório, inteiro em centavos e positivo.", @path)}
  end

  defp list_params(filter_opts) do
    params =
      filter_opts
      |> Pagination.params(@max_limit)
      |> Params.put_present(:status, Keyword.get(filter_opts, :status))
      |> Params.put_present(:barcode, Keyword.get(filter_opts, :barcode))

    Enum.reduce(@date_filters, params, fn filter, params ->
      Params.put_present(
        params,
        filter,
        filter_opts |> Keyword.get(filter) |> Params.format_date()
      )
    end)
  end

  defp item_path(payment_request_id),
    do: "#{@path}/#{Client.encode_path_segment(payment_request_id)}"
end
