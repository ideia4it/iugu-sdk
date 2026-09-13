defmodule Iugu.Invoice do
  @moduledoc """
  Fatura: a cobrança da Iugu que o cliente paga por Pix, boleto ou cartão.

  Uma fatura nasce `pending` com QR Code Pix, boleto e página de checkout
  (`secure_url`) já prontos, conforme `payable_with`. O pagamento chega pelo
  webhook `invoice.status_changed` e a liquidação por `invoice.released` e
  `invoice.split_released`; a documentação recomenda o webhook em vez de
  polling, e reler a fatura com `get/2` ao receber o evento.

  As regras de divisão ficam em `Iugu.Split`; a subconta que cria ou
  recebe, em `Iugu.Account`.

  ## Qual token

  Nenhuma rota daqui exige assinatura RSA. A fatura pertence à conta do token
  que a cria: a mestre com o token padrão do SDK, uma subconta com o
  `live_api_token` dela em `api_token:`. O `test_api_token` cria a mesma
  fatura em modo de teste, no mesmo host: não há sandbox separado. Isso
  importa para o split: "a conta que cria a transação paga as taxas iugu" e
  fica com o que sobra da divisão.

  ## Idempotência e retry

  `POST /v1/invoices` é a única rota deste módulo que aceita
  `Idempotency-Key`: "Se várias requisições forem enviadas com a mesma chave
  de idempotência no mesmo instante, apenas uma será processada com sucesso.
  Para as demais, será retornado o erro 409 (Conflito)", que o SDK devolve
  como `kind: :validation, status: 409`. Com a opção `:idempotency_key`,
  `create/2` liga o retry (`:transient`); sem ela **não repete**, porque um
  timeout pode ter criado a fatura e a segunda tentativa criaria outra,
  enviada por e-mail ao cliente. O TTL da chave e o corpo do 409 não estão
  documentados.

  Cancelar, capturar, reembolsar, gerar segunda via, marcar como paga
  externamente e reenviar e-mail não aceitam chave; a proteção é a
  pré-condição de status de cada rota (abaixo), que transforma a repetição
  num 400 em vez de numa segunda operação. Mesmo assim o retry fica desligado
  por padrão nas escritas.

  ## Ciclo de vida

  Os status documentados e o que cada rota exige:

    * `cancel/2`: `pending`, `in_analysis` ou `expired` ("Apenas faturas em
      análise ou pendentes podem ser canceladas"). É também como se libera
      uma pré-autorização de cartão
    * `capture/2`: só `in_analysis`, a primeira etapa da cobrança em duas
      etapas; sem captura nem cancelamento "em 7 dias corridos... o
      cancelamento será feito de forma automática pela iugu"
    * `refund/2` e `partial_refund/3`: só `paid`. Cartão aceita parcial e
      pede até 180 dias depois do pagamento; Pix só integral, até 90 dias;
      **boleto não reembolsa** por API (faça uma transferência). Precisa de
      saldo disponível: "Sem saldo disponível para reembolso". Com split, "o
      valor reembolsado será distribuído proporcionalmente entre as contas
      envolvidas", e a taxa MDR do reembolso fica com quem reembolsa
    * `duplicate/3`: só `pending`; "A fatura atual é cancelada e uma nova é
      criada com o mesmo status"
    * `reissue_expired/3`: só `expired` e só cobrança avulsa ("Não é possível
      reemitir faturas expiradas de carnês e assinaturas")
    * `mark_externally_paid/3`: só `pending`; sem tarifa da Iugu, e a fatura
      deixa de poder ser paga lá

  `paid?/1` é `paid` estrito; `final?/1` cobre os status em que não há mais o
  que esperar do cliente (`paid`, `externally_paid`, `canceled`, `expired`,
  `refunded`, `chargeback`). A tabela de transições ainda permite `canceled`
  e `expired` virarem `paid` por compensação tardia de boleto, então um
  webhook depois de `final?` não é impossível.

  ## Vencimento e expiração

  `due_date` (`AAAA-MM-DD`, hoje ou futuro, no máximo três ou quatro anos à
  frente, a documentação diz os dois) manda na multa e nos juros;
  `expires_in` é o número de dias **depois** do vencimento em que a fatura
  ainda pode ser paga, e passado isso ela vira `expired` e só volta com
  `reissue_expired/3`. A faixa de `expires_in` **não está confirmada**: o
  esquema diz 0 a 120, a tabela de erros diz 1 a 30, e os dois dizem que o
  limite é o da régua de cobrança da conta. Um guia oficial passa uma data
  em `expires_in`; o SDK aceita inteiro (dias) e `Date`, e manda os dois como
  string.

  ## Itens, pagador e formas de pagamento

  Cada item leva `description`, `quantity` (inteiro positivo) e `price_cents`
  com "valor mínimo de 100"; em `test_mode` são no máximo 30 itens. O total
  da fatura é a soma dos itens menos `discount_cents`, e é sobre ele que os
  percentuais de split incidem.

  `payable_with` é lista na requisição (`all`, `credit_card`, `bank_slip`,
  `pix`) e string na resposta. Boleto e Pix exigem `payer` com `cpf_cnpj` e
  `name`; o SDK confere isso quando a lista inclui `bank_slip`, `pix` ou
  `all`. Sem `payable_with`, valem as formas ativas na conta e a checagem fica
  com a Iugu. `email` é obrigatório a menos que `customer_id` venha, e a
  fatura é enviada para ele a menos que `ignore_due_email: true`.

  Abrir `secure_url` custa: "Quando o pagador acessa o link
  checkout.iugu.com, é cobrado uma tarifa". Mostre o QR Code (`pix/1`) e a
  linha digitável (`bank_slip/1`) na própria tela sempre que der.

  ## Modo de teste

  50 requisições por minuto (429), 1.000 faturas por dia, 30 itens por fatura,
  e o `pix.qrcode_text` é uma URL falsa em vez do payload EMV. Cartões de
  teste: `5555 5555 5555 4444` (Master), `4111 1111 1111 1111` (Visa) e
  `4012 8888 8888 1881` (Visa recusado).

  ## O que não está confirmado

    * se o `splits` da fatura substitui ou se soma ao split padrão da conta
    * a faixa efetiva de `expires_in` e de `bank_slip_extra_due` (1..30 ou
      1..120), e se `expires_in` aceita data
    * se `status_filter` aceita `in_analysis`, `in_protest`, `chargeback` e
      `draft` (a lista documentada tem oito valores mais `authorized`, cujo
      significado também não está descrito); `list/1` aceita todos e a Iugu
      decide
    * o status depois de um reembolso parcial (o evento
      `invoice.partially_refunded` existe, a tabela de status não tem valor
      para ele)
    * a forma do 404 em `get/2` e de "não encontrado" em
      `search_by_external_ids/3`, e o comportamento da busca com mais de um
      resultado
    * se `totalItems` respeita os filtros (a documentação diz que é o total
      da conta) e se o teto de 10.000 registros da paginação vale para
      faturas; `stream/1` para quando a página volta menor que `limit`
    * se os filtros de data aceitam `Z` além de `-03:00`; o SDK converte
      `DateTime` para o horário de São Paulo, o formato dos exemplos
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Pagination
  alias Iugu.Params
  alias Iugu.Response
  alias Iugu.Split

  @invoices_path "/v1/invoices"
  @resource_search_path "/v1/resource_search"
  @marketplace_resource_search_path "/v1/marketplace_resource_search"

  @max_limit 100
  @minimum_item_price_cents 100

  @statuses [
    "pending",
    "paid",
    "canceled",
    "in_analysis",
    "draft",
    "partially_paid",
    "refunded",
    "expired",
    "in_protest",
    "chargeback",
    "externally_paid"
  ]
  @final_statuses ["paid", "externally_paid", "canceled", "expired", "refunded", "chargeback"]
  @status_filters ["authorized" | @statuses]
  @payable_with ["all", "credit_card", "bank_slip", "pix"]
  @payer_required_methods ["all", "bank_slip", "pix"]
  @search_fields ["external_id", "order_id", "end_to_end", "digitable_line"]

  @create_fields [
    :email,
    :cc_emails,
    :due_date,
    :ensure_workday_due_date,
    :expires_in,
    :bank_slip_extra_due,
    :items,
    :payable_with,
    :payer,
    :splits,
    :customer_id,
    :subscription_id,
    :return_url,
    :expired_url,
    :notification_url,
    :ignore_canceled_email,
    :ignore_due_email,
    :fines,
    :late_payment_fine,
    :late_payment_fine_cents,
    :per_day_interest,
    :per_day_interest_value,
    :per_day_interest_cents,
    :discount_cents,
    :credits,
    :custom_variables,
    :early_payment_discount,
    :early_payment_discounts,
    :order_id,
    :external_reference,
    :max_installments_value,
    :soft_descriptor_light,
    :automatic_pix,
    :pix_qr_code_expires_at,
    :pix_remittance_info,
    :pix_additional_info,
    :password
  ]

  @duplicate_fields [
    :due_date,
    :items,
    :ignore_due_email,
    :ignore_canceled_email,
    :current_fines_option,
    :keep_early_payment_discount
  ]
  @reissue_fields [:payable_with | @duplicate_fields]

  @list_filters [
    :start,
    :limit,
    :created_at_from,
    :created_at_to,
    :paid_at_from,
    :paid_at_to,
    :due_date,
    :query,
    :updated_since,
    :customer_id,
    :status_filter
  ]
  @datetime_filters [:created_at_from, :created_at_to, :paid_at_from, :paid_at_to, :updated_since]

  @max_external_payment_id_length 32
  @max_external_payment_description_length 50
  @max_external_reference_length 60
  @max_soft_descriptor_length 12

  @type invoice :: map()

  @type page :: %{
          invoices: [invoice()],
          facets: map() | nil,
          page_info: Pagination.page_info()
        }

  @doc """
  Cria uma fatura. Veja o moduledoc sobre idempotência e retry.

  `attrs` usa os nomes da API em átomo. Obrigatórios: `:items` e `:due_date`,
  mais `:email` ou `:customer_id`. Conversões que o SDK faz:

    * `:due_date` aceita `Date`; `:expires_in` aceita inteiro (dias) ou
      `Date`; `:bank_slip_extra_due` aceita inteiro; todos saem como a rota
      pede
    * `:payable_with` aceita átomos ou strings e sai como lista de strings
    * `:splits` é uma lista de `t:Iugu.Split.t/0`, validada com
      `Iugu.Split.validate/3` contra o total da fatura (e contra
      `:own_account_id` das opções, quando informado) e convertida com
      `Iugu.Split.to_params/1`
    * `:cc_emails` aceita lista e sai separada por vírgula
    * `:pix_qr_code_expires_at` aceita `DateTime` e sai no formato
      `AAAA-MM-DDTHH:MM:SS-00:00` da documentação

  Antes da chamada o SDK recusa, com `kind: :validation, status: nil`, o que a
  Iugu recusaria com 422: item sem descrição, quantidade que não é inteiro
  positivo, `price_cents` abaixo de 100, `payable_with` fora do enum, boleto
  ou Pix sem `payer.cpf_cnpj` e `payer.name`, `late_payment_fine` e
  `late_payment_fine_cents` juntos ("Somente um campo de multa pode ser
  informado"), `soft_descriptor_light` acima de 12 caracteres e
  `external_reference` acima de 60. Uma chave fora da lista da rota levanta
  `ArgumentError`.

  Opções: `:idempotency_key` (vira o header e liga o retry) e as do
  `Iugu.Client`. A resposta é a fatura crua, `status: "pending"`.
  """
  @spec create(map(), keyword()) :: {:ok, invoice()} | {:error, Error.t()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    {create_opts, req_opts} = Keyword.split(opts, [:idempotency_key, :own_account_id])

    with {:ok, body} <- build_create_body(attrs, Keyword.get(create_opts, :own_account_id)) do
      Client.post(
        @invoices_path,
        body,
        Client.idempotency_options(req_opts, Keyword.get(create_opts, :idempotency_key))
      )
    end
  end

  @doc """
  Lê uma fatura pelo id.

  Com retry em falha transitória, como todo GET. A documentação só mostra
  `{}` para o 400; o 404 `{"errors":"Invoice Not Found"}` das outras rotas é
  a forma provável de "não encontrada" (`kind: :not_found`).
  """
  @spec get(String.t(), keyword()) :: {:ok, invoice()} | {:error, Error.t()}
  def get(invoice_id, opts \\ []) when is_binary(invoice_id) do
    Client.get(invoice_path(invoice_id), opts)
  end

  @doc """
  Lista as faturas da conta, da mais recente à mais antiga, até 100 por
  página.

  Filtros em opções: `:start`, `:limit` (preso a 100), `:created_at_from`,
  `:created_at_to`, `:paid_at_from`, `:paid_at_to`, `:updated_since`
  (`DateTime`, convertido para o horário de São Paulo, ou string já no
  formato `AAAA-MM-DDThh:mm:ss-03:00`), `:due_date` (`Date` ou
  `AAAA-MM-DD`), `:query` (texto livre sobre e-mail, nome, notas e
  `order_id`; "Necessário usar a paginação"), `:customer_id` e
  `:status_filter` (um de `statuses/0` ou `"authorized"`).

  Devolve `%{invoices, facets, page_info}`. `facets.status.terms` traz a
  contagem por status da conta; `page_info.total_items` é o `totalItems`
  da resposta, que a documentação define como o total da conta ignorando os
  filtros. Para pegar um pagamento duplicado, filtre por período e procure
  `original_payment_id` diferente de `nil`.
  """
  @spec list(keyword()) :: {:ok, page()} | {:error, Error.t()}
  def list(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, @list_filters)

    with {:ok, params} <- list_params(filter_opts),
         {:ok, body} <- Client.get(@invoices_path, Keyword.put(req_opts, :params, params)) do
      {:ok,
       %{
         invoices: Response.items(body),
         facets: Map.get(body, "facets"),
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

  Para quando a página volta menor que `limit`, sem olhar para `totalItems`,
  e levanta o `Iugu.Error` da primeira página que falhar.
  """
  @spec stream(keyword()) :: Enumerable.t()
  def stream(opts \\ []) do
    {page_opts, other_opts} = Keyword.split(opts, [:start, :limit])

    Pagination.stream(
      fn stream_page_opts ->
        with {:ok, page} <- list(Keyword.merge(other_opts, stream_page_opts)) do
          {:ok, page.invoices}
        end
      end,
      ["items"],
      Keyword.put(page_opts, :max_limit, @max_limit)
    )
  end

  @doc """
  Cancela uma fatura `pending`, `in_analysis` ou `expired`.

  `PUT /v1/invoices/{id}/cancel`, sem corpo. O cliente recebe o e-mail de
  cancelamento a menos que a fatura tenha sido criada com
  `ignore_canceled_email: true`. Fora desses status a Iugu responde 400
  `Apenas faturas em análise ou pendentes podem ser canceladas`.
  """
  @spec cancel(String.t(), keyword()) :: {:ok, invoice()} | {:error, Error.t()}
  def cancel(invoice_id, opts \\ []) when is_binary(invoice_id) do
    Client.request(:put, "#{invoice_path(invoice_id)}/cancel", opts)
  end

  @doc """
  Captura uma fatura `in_analysis` (cartão pré-autorizado na cobrança em
  duas etapas).

  `POST /v1/invoices/{id}/capture`, sem corpo; captura parcial **não está
  documentada**. A fatura volta `paid` e o webhook `invoice.status_changed`
  dispara. Fora de `in_analysis`: 400 `Apenas Faturas em análise podem ser
  capturadas`.
  """
  @spec capture(String.t(), keyword()) :: {:ok, invoice()} | {:error, Error.t()}
  def capture(invoice_id, opts \\ []) when is_binary(invoice_id) do
    Client.request(:post, "#{invoice_path(invoice_id)}/capture", opts)
  end

  @doc """
  Reembolsa uma fatura `paid` por inteiro. Veja o moduledoc sobre prazos por
  forma de pagamento.

  `POST /v1/invoices/{id}/refund`, sem corpo. A fatura volta `refunded` e o
  webhook `invoice.refund` dispara; o dinheiro chega ao pagador na hora no
  Pix e em 30 a 60 dias no cartão. Boleto responde erro: o reembolso é por
  transferência.
  """
  @spec refund(String.t(), keyword()) :: {:ok, invoice()} | {:error, Error.t()}
  def refund(invoice_id, opts \\ []) when is_binary(invoice_id) do
    Client.request(:post, refund_path(invoice_id), opts)
  end

  @doc """
  Reembolsa parte de uma fatura `paid` no cartão de crédito.

  Manda `partial_value_refund_cents`, "somente cartão de crédito"; Pix não
  aceita parcial. Acima do total a Iugu responde 400 `Valor maior que o
  permitido para reembolso.`; zero ou negativo o SDK recusa aqui. O status
  depois de um reembolso parcial **não está documentado**; confira
  `refunded_cents` na resposta.
  """
  @spec partial_refund(String.t(), pos_integer(), keyword()) ::
          {:ok, invoice()} | {:error, Error.t()}
  def partial_refund(invoice_id, refund_cents, opts \\ [])
      when is_binary(invoice_id) and is_integer(refund_cents) do
    path = refund_path(invoice_id)

    if refund_cents > 0 do
      Client.post(path, %{"partial_value_refund_cents" => refund_cents}, opts)
    else
      {:error, Error.validation("O valor do reembolso parcial precisa ser positivo.", path)}
    end
  end

  @doc """
  Gera a segunda via de uma fatura `pending`: cancela a atual e cria outra.

  `POST /v1/invoices/{id}/duplicate`. `attrs`: `:due_date` (obrigatório,
  `Date` ou `AAAA-MM-DD`, hoje ou futuro), `:items` (lista para incluir,
  editar ou remover: `%{id, description, quantity, price_cents, _destroy}`),
  `:ignore_due_email`, `:ignore_canceled_email`, `:current_fines_option`
  (copia multa e juros da original; ignorado quando a conta tem multa
  configurada) e `:keep_early_payment_discount`. A forma de pagamento não
  muda ("Faturas pendentes não podem alterar forma de pagamento").

  A resposta é a fatura **nova**, com outro `id`; a antiga passa a apontar
  para ela em `duplicated_invoice_id`. Os dias extras do boleto vêm de
  `bank_slip.reprint_extra_due` da conta.
  """
  @spec duplicate(String.t(), map(), keyword()) :: {:ok, invoice()} | {:error, Error.t()}
  def duplicate(invoice_id, attrs, opts \\ []) when is_binary(invoice_id) and is_map(attrs) do
    path = duplicate_path(invoice_id)

    with {:ok, body} <- build_duplicate_body(attrs, @duplicate_fields),
         :ok <- Params.validate_present(body, ["due_date"], path) do
      Client.post(path, body, opts)
    end
  end

  @doc """
  Reemite uma fatura `expired` de cobrança avulsa, como uma fatura nova
  `pending`.

  Mesma rota de `duplicate/3`; o que muda é o status de origem e os campos.
  Todos opcionais: `:due_date` (`Date` ou `AAAA-MM-DD`; omitido, "vai assumir
  o vencimento em 5 dias"), `:items` (aqui "valores negativos entram como
  desconto no total"), `:payable_with` (**string** única, `all`,
  `credit_card`, `bank_slip` ou `pix`; padrão o da fatura expirada),
  `:ignore_due_email`, `:ignore_canceled_email`, `:current_fines_option` e
  `:keep_early_payment_discount`. Fatura de carnê ou assinatura responde 400
  `Faturas expiradas originadas em Carnês ou Assinaturas não podem ser
  duplicadas.`.
  """
  @spec reissue_expired(String.t(), map(), keyword()) :: {:ok, invoice()} | {:error, Error.t()}
  def reissue_expired(invoice_id, attrs \\ %{}, opts \\ [])
      when is_binary(invoice_id) and is_map(attrs) do
    path = duplicate_path(invoice_id)

    with {:ok, body} <- build_duplicate_body(attrs, @reissue_fields),
         :ok <-
           Params.validate_member(
             Map.get(body, "payable_with"),
             @payable_with,
             "payable_with",
             path
           ) do
      Client.post(path, body, opts)
    end
  end

  @doc """
  Marca uma fatura `pending` como paga fora da Iugu.

  `PUT /v1/invoices/{id}/externally_pay` com `external_payment_id` (até 32
  caracteres, o seu identificador do pagamento) e a opção `:description`
  (`external_payment_description`, até 50). "Para esta baixa não haverá
  cobrança de tarifa", e a fatura deixa de poder ser paga na Iugu. Se o
  cliente já tinha pago e a compensação chega depois, a Iugu cria uma fatura
  nova `paid` e cobra a tarifa dela. A resposta volta `externally_paid` com
  `paid_at` preenchido.
  """
  @spec mark_externally_paid(String.t(), String.t(), keyword()) ::
          {:ok, invoice()} | {:error, Error.t()}
  def mark_externally_paid(invoice_id, external_payment_id, opts \\ [])
      when is_binary(invoice_id) and is_binary(external_payment_id) do
    path = "#{invoice_path(invoice_id)}/externally_pay"
    {body_opts, req_opts} = Keyword.split(opts, [:description])
    description = Keyword.get(body_opts, :description)

    with :ok <-
           Params.validate_length(
             external_payment_id,
             @max_external_payment_id_length,
             "external_payment_id",
             path
           ),
         :ok <-
           Params.validate_length(
             description,
             @max_external_payment_description_length,
             "external_payment_description",
             path
           ) do
      body =
        Params.put_present(
          %{"external_payment_id" => external_payment_id},
          "external_payment_description",
          description
        )

      Client.put(path, body, req_opts)
    end
  end

  @doc """
  Busca uma fatura por um identificador externo.

  `GET /v1/resource_search?query_field=...&value=...`. `query_field` é
  `"external_id"` (o `external_reference` da fatura), `"order_id"`,
  `"end_to_end"` (id Pix do pagamento ou do reembolso) ou
  `"digitable_line"` (linha digitável do boleto). Com a opção
  `marketplace: true` a rota passa a ser `/v1/marketplace_resource_search`,
  que "permite uma Conta Mestre consultar uma Fatura de uma Subconta" com o
  token da mestre.

  Devolve a fatura (o `resource` do envelope). A documentação fala em "uma
  Fatura": o que acontece com mais de um resultado, e a forma do "não
  encontrada", **não estão documentados**.
  """
  @spec search_by_external_ids(String.t(), String.t(), keyword()) ::
          {:ok, invoice()} | {:error, Error.t()}
  def search_by_external_ids(query_field, value, opts \\ [])
      when is_binary(query_field) and is_binary(value) do
    {search_opts, req_opts} = Keyword.split(opts, [:marketplace])

    path =
      if Keyword.get(search_opts, :marketplace, false),
        do: @marketplace_resource_search_path,
        else: @resource_search_path

    with :ok <- Params.validate_member(query_field, @search_fields, "query_field", path),
         {:ok, body} <-
           Client.get(
             path,
             Keyword.put(req_opts, :params, query_field: query_field, value: value)
           ) do
      case body do
        %{"resource" => %{} = invoice} ->
          {:ok, invoice}

        _other ->
          {:error,
           %Error{kind: :unexpected, path: path, body: body, messages: ["resposta sem resource"]}}
      end
    end
  end

  @doc """
  Reenvia a fatura por e-mail para o endereço vinculado a ela.

  `POST /v1/invoices/{id}/send_email`, sem corpo. Funciona também numa
  fatura paga (reenvia o recibo). Fatura inexistente responde 400 `Invoice
  Not Found` nesta rota, e não 404 como nas outras.
  """
  @spec send_email(String.t(), keyword()) :: {:ok, invoice()} | {:error, Error.t()}
  def send_email(invoice_id, opts \\ []) when is_binary(invoice_id) do
    Client.request(:post, "#{invoice_path(invoice_id)}/send_email", opts)
  end

  @doc "Os onze status documentados de uma fatura."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Formas de pagamento aceitas em `payable_with`."
  @spec payable_with() :: [String.t()]
  def payable_with, do: @payable_with

  @doc "Campos aceitos em `search_by_external_ids/3`."
  @spec search_fields() :: [String.t()]
  def search_fields, do: @search_fields

  @doc "Status da fatura, ou `nil` quando o mapa não é uma fatura."
  @spec status(invoice()) :: String.t() | nil
  def status(invoice) when is_map(invoice), do: Map.get(invoice, "status")

  @doc """
  Se o dinheiro entrou na Iugu: "Pix realizado, Boleto Bancário compensado
  ou transação de Cartão de Crédito capturada". `externally_paid` fica de
  fora de propósito, porque ali o dinheiro não passou pela Iugu.
  """
  @spec paid?(invoice()) :: boolean()
  def paid?(invoice), do: status(invoice) == "paid"

  @doc """
  Se não há mais o que esperar do cliente nesta fatura. Veja o moduledoc
  sobre a compensação tardia de boleto.
  """
  @spec final?(invoice()) :: boolean()
  def final?(invoice), do: status(invoice) in @final_statuses

  @doc "Página de checkout da Iugu. Abrir cobra tarifa; veja o moduledoc."
  @spec secure_url(invoice()) :: String.t() | nil
  def secure_url(invoice) when is_map(invoice), do: Map.get(invoice, "secure_url")

  @doc "PDF da fatura, que é `secure_url` com `.pdf` (forma dos exemplos de cobrança direta)."
  @spec pdf_url(invoice()) :: String.t() | nil
  def pdf_url(invoice) do
    case secure_url(invoice) do
      nil -> nil
      url -> url <> ".pdf"
    end
  end

  @doc """
  Dados do Pix da fatura, ou `nil` quando não há QR Code.

  `qrcode` é a URL da imagem, `qrcode_text` o "copia e cola" (payload EMV;
  em modo de teste, uma URL falsa), `status` `qr_code_created` antes do
  pagamento e `paid` depois, `end_to_end_id` o id do pagamento Pix. O objeto
  `pix` vem preenchido com `null` mesmo sem Pix na fatura; por isso o
  critério é ter `qrcode`.
  """
  @spec pix(invoice()) ::
          %{
            qrcode: String.t(),
            qrcode_text: String.t() | nil,
            status: String.t() | nil,
            end_to_end_id: String.t() | nil
          }
          | nil
  def pix(invoice) when is_map(invoice) do
    case Map.get(invoice, "pix") do
      %{"qrcode" => qrcode} = pix when is_binary(qrcode) ->
        %{
          qrcode: qrcode,
          qrcode_text: Map.get(pix, "qrcode_text"),
          status: Map.get(pix, "status"),
          end_to_end_id: Map.get(pix, "end_to_end_id")
        }

      _other ->
        nil
    end
  end

  @doc """
  Dados do boleto, ou `nil` quando a fatura não tem boleto (`bank_slip` vem
  `null` sem `bank_slip` em `payable_with` e depois de `mark_externally_paid/3`).

  `digitable_line` tem 47 dígitos, `barcode_data` 44; `barcode_url` é a
  imagem do código de barras, `url` a página do boleto e `pdf_url` o PDF.
  `status` é o registro no banco (`pending`, `registered`; o webhook
  `invoice.bank_slip_status` fala também em `processing`, `canceled`, `none`
  e `error`).
  """
  @spec bank_slip(invoice()) ::
          %{
            digitable_line: String.t() | nil,
            barcode_data: String.t() | nil,
            barcode_url: String.t() | nil,
            url: String.t() | nil,
            pdf_url: String.t() | nil,
            bank: integer() | nil,
            status: String.t() | nil
          }
          | nil
  def bank_slip(invoice) when is_map(invoice) do
    case Map.get(invoice, "bank_slip") do
      %{} = bank_slip ->
        %{
          digitable_line: Map.get(bank_slip, "digitable_line"),
          barcode_data: Map.get(bank_slip, "barcode_data"),
          barcode_url: Map.get(bank_slip, "barcode"),
          url: Map.get(bank_slip, "bank_slip_url"),
          pdf_url: Map.get(bank_slip, "bank_slip_pdf_url"),
          bank: Response.integer(bank_slip, ["bank_slip_bank"]),
          status: Map.get(bank_slip, "bank_slip_status")
        }

      _other ->
        nil
    end
  end

  @doc "Regras de split aplicadas à fatura (`split_rules`), como `t:Iugu.Split.t/0`."
  @spec splits(invoice()) :: [Split.t()]
  def splits(invoice) when is_map(invoice), do: Split.from_payload(invoice)

  defp build_create_body(attrs, own_account_id) do
    attrs =
      Map.new(attrs, fn {key, value} -> {Params.field!(key, @create_fields, "fatura"), value} end)

    items = attrs |> Map.get(:items, []) |> List.wrap() |> Enum.map(&Params.stringify_keys/1)
    total_cents = items_total_cents(items) - (Map.get(attrs, :discount_cents) || 0)
    splits = attrs |> Map.get(:splits, []) |> List.wrap()
    payable_with = attrs |> Map.get(:payable_with) |> normalize_payable_with()

    with :ok <- validate_items(items),
         :ok <- validate_email_or_customer(attrs),
         :ok <- Params.validate_present(attrs, [:due_date], @invoices_path),
         :ok <- validate_payable_with(payable_with),
         :ok <- validate_payer(payable_with, Map.get(attrs, :payer)),
         :ok <- validate_fines(attrs),
         :ok <-
           Params.validate_length(
             Map.get(attrs, :soft_descriptor_light),
             @max_soft_descriptor_length,
             "soft_descriptor_light",
             @invoices_path
           ),
         :ok <-
           Params.validate_length(
             Map.get(attrs, :external_reference),
             @max_external_reference_length,
             "external_reference",
             @invoices_path
           ),
         :ok <- validate_splits(splits, total_cents, own_account_id) do
      body =
        attrs
        |> Map.drop([:items, :splits, :payable_with, :cc_emails, :pix_qr_code_expires_at])
        |> Map.new(fn {key, value} -> {Atom.to_string(key), convert_create_value(key, value)} end)
        |> Map.put("items", items)
        |> Params.put_present("payable_with", payable_with)
        |> Params.put_present("cc_emails", join_emails(Map.get(attrs, :cc_emails)))
        |> Params.put_present(
          "pix_qr_code_expires_at",
          format_utc_datetime(Map.get(attrs, :pix_qr_code_expires_at))
        )
        |> put_splits(splits)

      {:ok, body}
    end
  end

  defp build_duplicate_body(attrs, fields) do
    body =
      attrs
      |> Map.new(fn {key, value} -> {Params.field!(key, fields, "fatura"), value} end)
      |> Map.new(fn
        {:due_date, value} -> {"due_date", Params.format_date(value)}
        {:items, items} -> {"items", items |> List.wrap() |> Enum.map(&Params.stringify_keys/1)}
        {:payable_with, method} -> {"payable_with", method && to_string(method)}
        {key, value} -> {Atom.to_string(key), value}
      end)

    {:ok, body}
  end

  defp convert_create_value(:due_date, value), do: Params.format_date(value)
  defp convert_create_value(:expires_in, %Date{} = date), do: Date.to_iso8601(date)
  defp convert_create_value(:expires_in, days) when is_integer(days), do: Integer.to_string(days)

  defp convert_create_value(:bank_slip_extra_due, days) when is_integer(days),
    do: Integer.to_string(days)

  defp convert_create_value(_key, value), do: value

  defp list_params(filter_opts) do
    with :ok <-
           Params.validate_member(
             Keyword.get(filter_opts, :status_filter),
             @status_filters,
             "status_filter",
             @invoices_path
           ) do
      params =
        filter_opts
        |> Pagination.params(@max_limit)
        |> Params.put_present(
          :due_date,
          filter_opts |> Keyword.get(:due_date) |> Params.format_date()
        )
        |> Params.put_present(:query, Keyword.get(filter_opts, :query))
        |> Params.put_present(:customer_id, Keyword.get(filter_opts, :customer_id))
        |> Params.put_present(:status_filter, Keyword.get(filter_opts, :status_filter))

      params =
        Enum.reduce(@datetime_filters, params, fn filter, params ->
          Params.put_present(
            params,
            filter,
            filter_opts |> Keyword.get(filter) |> Params.format_local_datetime()
          )
        end)

      {:ok, params}
    end
  end

  defp items_total_cents(items) do
    Enum.reduce(items, 0, fn item, total ->
      quantity = Map.get(item, "quantity")
      price_cents = Map.get(item, "price_cents")

      if is_integer(quantity) and is_integer(price_cents),
        do: total + quantity * price_cents,
        else: total
    end)
  end

  defp validate_items([]) do
    {:error, Error.validation("A fatura precisa de pelo menos um item.", @invoices_path)}
  end

  defp validate_items(items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case validate_item(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_item(%{
         "description" => description,
         "quantity" => quantity,
         "price_cents" => cents
       })
       when is_binary(description) and description != "" and is_integer(quantity) and quantity > 0 and
              is_integer(cents) and cents >= @minimum_item_price_cents,
       do: :ok

  defp validate_item(item) do
    {:error,
     Error.validation(
       "Item inválido: #{inspect(item)}. Cada item precisa de description, quantity inteiro positivo e price_cents inteiro de no mínimo 100.",
       @invoices_path
     )}
  end

  defp validate_email_or_customer(attrs) do
    if Params.present?(attrs, :email) or Params.present?(attrs, :customer_id) do
      :ok
    else
      {:error, Error.validation("Informe email ou customer_id para a fatura.", @invoices_path)}
    end
  end

  defp normalize_payable_with(nil), do: nil
  defp normalize_payable_with(methods), do: methods |> List.wrap() |> Enum.map(&to_string/1)

  defp validate_payable_with(nil), do: :ok

  defp validate_payable_with(methods) do
    case methods -- @payable_with do
      [] ->
        :ok

      unknown ->
        {:error,
         Error.validation(
           "payable_with inválido: #{inspect(unknown)}. Use um de #{inspect(@payable_with)}.",
           @invoices_path
         )}
    end
  end

  defp validate_payer(nil, _payer), do: :ok

  defp validate_payer(methods, payer) do
    payer = if is_map(payer), do: Params.stringify_keys(payer), else: %{}

    if Enum.any?(methods, &(&1 in @payer_required_methods)) and
         not (Params.present?(payer, "cpf_cnpj") and Params.present?(payer, "name")) do
      {:error,
       Error.validation(
         "Boleto e Pix exigem payer com cpf_cnpj e name.",
         @invoices_path
       )}
    else
      :ok
    end
  end

  defp validate_fines(attrs) do
    if Params.present?(attrs, :late_payment_fine) and
         Params.present?(attrs, :late_payment_fine_cents) do
      {:error,
       Error.validation(
         "Somente um campo de multa pode ser informado: late_payment_fine ou late_payment_fine_cents.",
         @invoices_path
       )}
    else
      :ok
    end
  end

  defp validate_splits([], _total_cents, _own_account_id), do: :ok

  defp validate_splits(splits, total_cents, own_account_id) do
    with {:error, %Error{} = error} <-
           Split.validate(splits, total_cents, own_account_id: own_account_id) do
      {:error, %Error{error | path: @invoices_path}}
    end
  end

  defp put_splits(body, []), do: body
  defp put_splits(body, splits), do: Map.put(body, "splits", Split.to_params(splits))

  defp join_emails(nil), do: nil
  defp join_emails(emails) when is_list(emails), do: Enum.join(emails, ", ")
  defp join_emails(emails) when is_binary(emails), do: emails

  # pix_qr_code_expires_at é documentado como AAAA-MM-DDTHH:MM:SS-00:00, que é
  # UTC escrito com um offset zero explícito em vez de Z.
  defp format_utc_datetime(nil), do: nil

  defp format_utc_datetime(%DateTime{} = datetime) do
    datetime
    |> DateTime.shift_zone!("Etc/UTC")
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
    |> String.replace_suffix("Z", "-00:00")
  end

  defp format_utc_datetime(datetime) when is_binary(datetime), do: datetime

  defp invoice_path(invoice_id), do: "#{@invoices_path}/#{Client.encode_path_segment(invoice_id)}"
  defp refund_path(invoice_id), do: "#{invoice_path(invoice_id)}/refund"
  defp duplicate_path(invoice_id), do: "#{invoice_path(invoice_id)}/duplicate"
end
