defmodule Iugu.Charge do
  @moduledoc """
  Cobrança direta: cartão de crédito cobrado na hora ou boleto registrado
  emitido na hora.

  A documentação compara: cobrança direta é pagar no balcão, fatura é a conta
  do restaurante com vencimento. Toda cobrança direta **cria uma fatura por
  baixo** (a resposta traz `invoice_id`, `url` do checkout e `pdf`), e
  `invoice_id` na chamada faz o contrário: paga uma fatura que já existe.

  ## Só cartão e boleto

  `POST /v1/charge` aceita cartão de crédito (via `token`,
  `customer_payment_method_id` ou o cartão padrão do `customer_id`) e
  `method: "bank_slip"`. **Pix não existe aqui**: "Diferente do Cobrança
  Direta, em Criar Fatura é possível adicionar o pix como método de
  pagamento". Para Pix, crie a fatura com `payable_with: ["pix"]` em
  `Iugu.Invoice.create/2` e leia `Iugu.Invoice.pix/1`.

  Também não há `splits` nesta rota. O split entra pelo split padrão da
  conta (`Iugu.Split.set_default/2`) ou criando a fatura com
  `splits` e cobrando-a aqui com `invoice_id`. Multa, juros e desconto por
  antecipação são igualmente coisa de fatura.

  ## Qual token

  Sem assinatura RSA. O `live_api_token` ou `test_api_token` da conta que
  cobra: o padrão do SDK para a mestre, `api_token:` para uma subconta. Num
  marketplace a subconta pode cobrar um token criado com o `account_id` da
  mestre e um `customer_payment_method_id` de cliente da mestre
  compartilhado (`Iugu.Customer.share_payment_methods_from/3`).

  ## Recusa é 200

  A Iugu responde **HTTP 200 com `"success": false`** quando o emissor nega o
  cartão. `create/2` converte isso em `{:error, %Iugu.Error{kind:
  :declined}}` com o código do adquirente em `lr` (`"51"` saldo
  insuficiente, `"54"` cartão vencido) e a mensagem em `messages`; nunca
  decida pelo status HTTP. `lr_category/1` agrupa a tabela de LRs no que
  importa para a tela: repetir mais tarde, pedir outro cartão, corrigir os
  dados. A forma completa do JSON recusado **não está documentada** (só a
  linha do log da fatura, "LR: 05"); os campos lidos são os do sucesso.

  ## Token de uso único, idempotência e retry

  "Qualquer retorno (sucesso ou falha) à requisição ao endpoint v1/charge
  tornará o token inutilizável." Uma nova tentativa precisa de outro token ou
  de um cartão salvo. A página de idempotência lista a cobrança direta entre
  as rotas que aceitam `Idempotency-Key` (a página da própria rota não a
  menciona); com a opção `:idempotency_key`, `create/2` manda o header e liga
  o retry (`:transient`), e um 409 na repetição significa que a primeira
  tentativa chegou à Iugu, então a cobrança existe e o token já morreu. Sem a
  chave `create/2` **nunca repete**, mesmo com `retry:` na opção: um timeout
  pode ter cobrado o cartão, e a conciliação é por `list_transactions/1` ou
  pelo webhook `invoice.status_changed`. `order_id` "ajuda a evitar o
  pagamento da mesma fatura", mas se a Iugu recusa a duplicata ou só a
  registra **não está confirmado**.

  Por padrão "a fatura é cancelada caso haja falha na cobrança"; com
  `keep_dunning: true` ela fica `pending` para o cliente pagar de outro
  jeito (só para faturas criadas nesta chamada). Cada cartão aceita "até
  cinco (5) tentativas de pagamento" no mês; depois disso só no mês seguinte.
  Uma cobrança que aparece no extrato do cliente sem a fatura ficar `paid` é
  estornada "dentro de 7 a 10 dias úteis".

  ## Parcelas, descritor e boleto

  `months` vai de 2 a 12 (à vista, não mande), até o `max_installments` da
  conta, com parcela mínima de R$ 5,00. `soft_descriptor_light` tem no
  máximo 12 caracteres e aparece no extrato depois do prefixo fixo `Iugu*`.
  Boleto exige `payer` com `cpf_cnpj` e `name` (e, para registro,
  `address.zip_code` e `address.number`; o exemplo oficial omite o endereço
  e o 422 documentado o exige, então mande), vence em 3 dias corridos ou em
  `bank_slip_extra_days`, e `restrict_payment_method: true` tranca o checkout
  no boleto. Itens: até 30, `price_cents` negativo entra como desconto, e o
  total precisa passar de R$ 1,00 (422 `total: deve ser maior que 1`).

  ## Duas etapas e dois cartões

  Com `credit_card.two_step_transaction` na conta, a cobrança só autoriza e a
  fatura vai para `in_analysis`; `Iugu.Invoice.capture/2` captura e
  `Iugu.Invoice.cancel/2` libera, com cancelamento automático em 7
  dias. O `status` da resposta nesse caso **não está documentado**
  (provavelmente `authorized`).

  `create_with_two_cards/3` divide uma fatura entre dois cartões
  (`POST /v1/charge_two_credit_cards`), recurso "em fase inicial": exige a
  fatura criada antes, `two_credit_cards_payment` ligado na conta, sem
  parcelamento, sem assinatura, estorno só total. O `api_token` vai no
  **corpo** nessa rota.

  ## O que não está confirmado

    * o JSON exato de uma recusa (`status`, `message`, `errors`, se
      `invoice_id` vem) e o `status` em modo duas etapas
    * se `order_id` impede a duplicata ou é só informativo
    * se `email` é obrigatório com `customer_id` sem `invoice_id` (o SDK
      aceita `email`, `customer_id` ou `payer.email`)
    * se o boleto exige `payer.address` hoje, e se o limite diário de faturas
      vale para as criadas por aqui
    * se o split padrão da subconta se aplica às faturas criadas pela
      cobrança direta (a documentação sugere que sim)
    * nos dois cartões, se as parcelas precisam somar o total da fatura e o
      que acontece quando só um cartão é aprovado
    * nenhum limite de requisições nem 429 está documentado para estas rotas
  """

  alias Iugu.Client
  alias Iugu.Config
  alias Iugu.Error
  alias Iugu.Pagination
  alias Iugu.Params
  alias Iugu.Response

  @path "/v1/charge"
  @two_cards_path "/v1/charge_two_credit_cards"
  @transactions_path "/v1/credit_card_transactions"

  @bank_slip "bank_slip"
  @max_items 30
  @minimum_total_cents 100
  @minimum_installment_cents 500
  @installments 2..12
  @max_soft_descriptor_length 12
  @max_limit 100

  @create_fields [
    :method,
    :token,
    :customer_payment_method_id,
    :customer_id,
    :invoice_id,
    :email,
    :restrict_payment_method,
    :months,
    :discount_cents,
    :bank_slip_extra_days,
    :keep_dunning,
    :items,
    :payer,
    :order_id,
    :soft_descriptor_light
  ]
  @payment_means [:token, :customer_payment_method_id, :customer_id]

  @transaction_statuses [
    "captured",
    "authorized",
    "canceled",
    "canceling",
    "invalid",
    "partially_canceled",
    "pending",
    "technical_issue",
    "unauthorized"
  ]
  @transaction_filters [:start, :limit, :created_at_from, :created_at_to, :status]
  @datetime_filters [:created_at_from, :created_at_to]

  # A tabela de LR, agrupada pelo que a tela faz em seguida. Os códigos ficam do
  # jeito que a tabela os imprime; normalize_lr/1 leva "05" para "5" antes.
  @authorized_lrs ~w(0 00 11)
  @lr_categories %{
    retry_later:
      ~w(28 60 89 91 92 96 98 99 999 99A 99B 99C 99TA 99Z AA BP900 BP901 BP902 BP903 BP904 475 911 912),
    fix_card_data: ~w(1 12 14 15 30 54 56 63 AV BM C2 KA U3 6P),
    installments: ~w(22 23 24 EB EE),
    do_not_retry: ~w(4 7 41 43 46 57 59 62 74 81 88 93 R0 R1 R2 R3 SC AF01 AF02 IR 146 5C),
    insufficient_funds: ~w(51 61 70 DM BL N4)
  }

  @type charge :: map()

  @type lr_category ::
          :authorized
          | :retry_later
          | :fix_card_data
          | :installments
          | :do_not_retry
          | :insufficient_funds
          | :unknown

  @type transactions_page :: %{transactions: [map()], page_info: Pagination.page_info()}

  @doc """
  Cobra na hora com cartão ou emite um boleto. Leia "Recusa é 200" no
  moduledoc.

  `attrs` usa os nomes da API em átomo ou string. A forma de pagar é uma de:

    * `:token` de `Iugu.PaymentToken.create/3` (uso único)
    * `:customer_payment_method_id` de um cartão salvo
    * só `:customer_id`, quando o cliente tem cartão padrão
    * `:method` `"bank_slip"` (ou `:bank_slip`), o único valor da chave;
      cartão é implícito pelos campos acima e nunca vai em `method`

  O resto: `:items` (obrigatório sem `invoice_id`: até 30 de `%{description,
  quantity, price_cents}`), `:email` (proibido com `invoice_id`),
  `:customer_id`, `:invoice_id` (paga uma fatura existente; `payer`,
  `customer_id` e `items` são herdados dela), `:payer` (`cpf_cnpj`, `name`,
  `email`, `phone_prefix`, `phone`, `address` com `zip_code`, `number`,
  `street`, `district`, `city`, `state`, `complement`), `:months` (2 a 12),
  `:discount_cents`, `:bank_slip_extra_days`, `:keep_dunning`,
  `:restrict_payment_method`, `:order_id` e `:soft_descriptor_light`. Em
  `opts`, `:idempotency_key` vira o header `Idempotency-Key` e liga o retry
  (veja o moduledoc).

  Antes da chamada o SDK recusa, com `kind: :validation, status: nil`:
  nenhuma forma de pagar, `token` junto de `customer_payment_method_id`,
  `method` fora de `bank_slip` ou junto de um cartão, `email` ou `items` com
  `invoice_id`, itens ausentes, acima de 30 ou inválidos, total abaixo de
  R$ 1,00, nenhum e-mail (`email`, `customer_id` ou `payer.email`) sem
  `invoice_id`, boleto sem `payer.cpf_cnpj` e `name` (sem `invoice_id` nem
  `customer_id`), `months` fora de 2..12, no boleto ou com parcela abaixo de
  R$ 5,00, e `soft_descriptor_light` acima de 12. Chave desconhecida levanta
  `ArgumentError`.

  Sucesso é `{:ok, resposta}` com `success: true`; leia `invoice_id/1`,
  `url/1`, `pdf_url/1`, `card/1` e `bank_slip/1`. Cartão negado é `{:error,
  %Error{kind: :declined, lr: ...}}`; um 200 sem `success` é `:unexpected`.
  Sem `:idempotency_key`, nunca repete.
  """
  @spec create(map(), keyword()) :: {:ok, charge()} | {:error, Error.t()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    {idempotency_key, req_opts} = Keyword.pop(opts, :idempotency_key)

    with {:ok, body} <- build_create_body(attrs),
         {:ok, response} <-
           Client.post(@path, body, Client.idempotency_options(req_opts, idempotency_key)) do
      read_outcome(response, @path)
    end
  end

  @doc """
  Paga uma fatura existente com dois cartões, cada um com sua parte.

  `payments` são exatamente dois `%{token, amount_cents}`; o token de cada
  cartão vem de `Iugu.PaymentToken.create/3` (uma chamada por
  cartão). A rota lê o `api_token` no corpo, então o SDK o copia de
  `api_token:` ou do padrão. Só faturas avulsas com `credit_card` ou `all`
  em `payable_with`, sem parcelamento; o recurso precisa estar ligado
  (`credit_card.two_credit_cards_payment` em
  `Iugu.Account.configure/2`).

  Devolve `%{invoice_status, transactions, body}` quando os dois cartões
  passam. Se qualquer um voltar `success: false` o resultado é
  `kind: :declined` com o LR daquele cartão; o que a Iugu faz com o cartão
  aprovado nesse caso **não está documentado** (estorno parcial não existe
  aqui). Sem retry.
  """
  @spec create_with_two_cards(String.t(), [map()], keyword()) ::
          {:ok, %{invoice_status: String.t() | nil, transactions: [map()], body: map()}}
          | {:error, Error.t()}
  def create_with_two_cards(invoice_id, payments, opts \\ [])
      when is_binary(invoice_id) and is_list(payments) do
    with {:ok, legs} <- build_two_cards_legs(payments) do
      body = %{
        "api_token" => Keyword.get(opts, :api_token) || Config.api_token!(),
        "invoice_id" => invoice_id,
        "iugu_credit_card_payment" => legs
      }

      with {:ok, response} <- Client.post(@two_cards_path, body, opts) do
        read_two_cards_outcome(response)
      end
    end
  end

  @doc """
  Lista as transações de cartão da conta, para conciliar uma cobrança cujo
  resultado se perdeu.

  `GET /v1/credit_card_transactions`, `live_api_token` ou `test_api_token`,
  mestre ou subconta. Filtros: `:start`, `:limit` (preso a 100),
  `:created_at_from`, `:created_at_to` (`DateTime`, convertido para o horário
  de São Paulo, ou string `AAAA-MM-DDThh:mm:ss-03:00`) e `:status` (um de
  `transaction_statuses/0`). Cada item traz `invoice_id`, `status`, `lr`,
  `authorize_lr`, `cancel_lr`, `holder_name`, `bin`, `last4`, `tid`, `nsu`,
  `payer_cpf_cnpj`, `test_mode`. Token errado responde 400
  `{"errors": "Unauthorized"}`, e não 401.
  """
  @spec list_transactions(keyword()) :: {:ok, transactions_page()} | {:error, Error.t()}
  def list_transactions(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, @transaction_filters)

    with :ok <-
           Params.validate_member(
             Keyword.get(filter_opts, :status),
             @transaction_statuses,
             "status",
             @transactions_path
           ),
         params = transaction_params(filter_opts),
         {:ok, body} <- Client.get(@transactions_path, Keyword.put(req_opts, :params, params)) do
      {:ok,
       %{
         transactions: Response.items(body),
         page_info:
           Pagination.page_info(body,
             start: Map.get(params, :start, 0),
             limit: Map.get(params, :limit)
           )
       }}
    end
  end

  @doc """
  Percorre todas as páginas de `list_transactions/1` com os mesmos filtros.

  Para na primeira página menor que `limit` e levanta o
  `Iugu.Error` da primeira página que falhar.
  """
  @spec stream_transactions(keyword()) :: Enumerable.t()
  def stream_transactions(opts \\ []) do
    {page_opts, other_opts} = Keyword.split(opts, [:start, :limit])

    Pagination.stream(
      fn stream_page_opts ->
        with {:ok, page} <- list_transactions(Keyword.merge(other_opts, stream_page_opts)) do
          {:ok, page.transactions}
        end
      end,
      ["items"],
      Keyword.put(page_opts, :max_limit, @max_limit)
    )
  end

  @doc "Os nove status de transação de cartão documentados."
  @spec transaction_statuses() :: [String.t()]
  def transaction_statuses, do: @transaction_statuses

  @doc "Id da fatura criada ou paga pela cobrança."
  @spec invoice_id(charge()) :: String.t() | nil
  def invoice_id(charge) when is_map(charge), do: Map.get(charge, "invoice_id")

  @doc "Página de checkout da fatura. Abrir cobra tarifa; prefira `bank_slip/1` na tela."
  @spec url(charge()) :: String.t() | nil
  def url(charge) when is_map(charge), do: Map.get(charge, "url")

  @doc "PDF da fatura (`pdf` da resposta)."
  @spec pdf_url(charge()) :: String.t() | nil
  def pdf_url(charge) when is_map(charge), do: Map.get(charge, "pdf")

  @doc "Linha digitável do boleto (47 dígitos), ou `nil` numa cobrança de cartão."
  @spec identification(charge()) :: String.t() | nil
  def identification(charge) when is_map(charge), do: Map.get(charge, "identification")

  @doc "Se a Iugu aceitou a cobrança (`success: true`). Numa recusa `create/2` já devolveu erro."
  @spec authorized?(charge()) :: boolean()
  def authorized?(charge) when is_map(charge), do: Map.get(charge, "success") == true

  @doc "Código de retorno do adquirente (`LR`), como string, ou `nil`."
  @spec lr(charge()) :: String.t() | nil
  def lr(charge) when is_map(charge) do
    case Response.get_any(charge, ["LR", "lr"]) do
      nil -> nil
      code -> to_string(code)
    end
  end

  @doc """
  Dados do boleto emitido, ou `nil` quando a cobrança não é boleto.

  `digitable_line` é a linha digitável; `url` e `pdf_url` são as páginas do
  boleto em `boletos.iugu.com` (`bank_slip_url`, `bank_slip_pdf_url`, que
  exemplos mais antigos omitem e então vêm `nil`). A compensação chega pelo
  webhook `invoice.status_changed` com `paid`.
  """
  @spec bank_slip(charge()) ::
          %{digitable_line: String.t(), url: String.t() | nil, pdf_url: String.t() | nil} | nil
  def bank_slip(charge) when is_map(charge) do
    case identification(charge) do
      digitable_line when is_binary(digitable_line) ->
        %{
          digitable_line: digitable_line,
          url: Map.get(charge, "bank_slip_url"),
          pdf_url: Map.get(charge, "bank_slip_pdf_url")
        }

      _other ->
        nil
    end
  end

  @doc """
  Dados da transação de cartão, ou `nil` quando a resposta não traz `LR`
  (boleto).

  `status` é o da transação (`captured`, ou `authorized` em duas etapas),
  `transaction_token` o identificador do adquirente (não é o token de
  cartão), `reversible?` se ainda cabe estorno. `brand`, `bin`, `last4` e
  `issuer` vêm `nil` nos exemplos de teste.
  """
  @spec card(charge()) ::
          %{
            status: String.t() | nil,
            lr: String.t(),
            message: String.t() | nil,
            info_message: String.t() | nil,
            brand: String.t() | nil,
            bin: String.t() | nil,
            last4: String.t() | nil,
            issuer: String.t() | nil,
            reversible?: boolean() | nil,
            transaction_token: String.t() | nil
          }
          | nil
  def card(charge) when is_map(charge) do
    case lr(charge) do
      nil ->
        nil

      lr ->
        %{
          status: Map.get(charge, "status"),
          lr: lr,
          message: Map.get(charge, "message"),
          info_message: Map.get(charge, "info_message"),
          brand: Map.get(charge, "brand"),
          bin: stringify_or_nil(Map.get(charge, "bin")),
          last4: stringify_or_nil(Map.get(charge, "last4")),
          issuer: Map.get(charge, "issuer"),
          reversible?: Map.get(charge, "reversible"),
          transaction_token: Map.get(charge, "token")
        }
    end
  end

  @doc """
  O que fazer com um LR, segundo a tabela de LRs da Iugu.

    * `:authorized`: `00`, `0` e `11` (cartão emitido no exterior)
    * `:retry_later`: emissor fora do ar, timeout, falha de sistema (`91`,
      `96`, `98`, `99A`...); vale repetir com **outro token** em minutos
    * `:fix_card_data`: número, validade ou CVV errados (`12`, `14`, `54`);
      peça ao cliente para conferir
    * `:installments`: parcelamento não aceito (`22`, `23`, `24`, `EB`, `EE`)
    * `:insufficient_funds`: `51`, `61`, `70`, `DM`; outro cartão ou boleto
    * `:do_not_retry`: cartão perdido, roubado, fraude, "não tente novamente"
      (`41`, `43`, `7`, `59`, `AF01`, `AF02`); a tabela marca como
      irreversível, e insistir só gasta as cinco tentativas do mês
    * `:unknown`: código fora da tabela ou `nil`

  Aceita a string da resposta (`"05"` e `"5"` são o mesmo código) ou o erro
  `kind: :declined`.

      iex> Iugu.Charge.lr_category("00")
      :authorized

      iex> Iugu.Charge.lr_category("51")
      :insufficient_funds

      iex> Iugu.Charge.lr_category("05")
      :unknown

      iex> Iugu.Charge.lr_category("41")
      :do_not_retry

      iex> Iugu.Charge.lr_category(%Iugu.Error{kind: :declined, lr: "91"})
      :retry_later
  """
  @spec lr_category(String.t() | Error.t() | nil) :: lr_category()
  def lr_category(%Error{lr: lr}), do: lr_category(lr)
  def lr_category(nil), do: :unknown

  def lr_category(lr) when is_binary(lr) do
    code = normalize_lr(lr)

    if code in @authorized_lrs do
      :authorized
    else
      Enum.find_value(@lr_categories, :unknown, fn {category, codes} ->
        code in codes && category
      end)
    end
  end

  # "05" no log da fatura e "5" na tabela são o mesmo código; "00" fica como
  # está porque é o valor de sucesso documentado.
  defp normalize_lr("00"), do: "00"

  defp normalize_lr(lr) do
    case Regex.run(~r/\A0(\d)\z/, lr) do
      [_match, digit] -> digit
      nil -> String.upcase(lr)
    end
  end

  defp build_create_body(attrs) do
    attrs =
      Map.new(attrs, fn {key, value} ->
        {Params.field!(key, @create_fields, "cobrança"), value}
      end)

    method = attrs |> Map.get(:method) |> normalize_method()
    items = attrs |> Map.get(:items, []) |> List.wrap() |> Enum.map(&Params.stringify_keys/1)
    payer = attrs |> Map.get(:payer) |> normalize_payer()
    invoice_id = Map.get(attrs, :invoice_id)
    total_cents = if invoice_id, do: nil, else: items_total_cents(items, attrs)

    with :ok <- validate_method(method),
         :ok <- validate_payment_means(attrs, method),
         :ok <- validate_invoice_inheritance(attrs, invoice_id),
         :ok <- validate_items(items, invoice_id),
         :ok <- validate_total(total_cents),
         :ok <- validate_email(attrs, payer, invoice_id),
         :ok <- validate_payer(method, attrs, payer, invoice_id),
         :ok <- validate_months(Map.get(attrs, :months), method, total_cents),
         :ok <-
           Params.validate_length(
             Map.get(attrs, :soft_descriptor_light),
             @max_soft_descriptor_length,
             "soft_descriptor_light",
             @path
           ) do
      body =
        attrs
        |> Map.drop([:method, :items, :payer])
        |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
        |> Params.put_present("method", method)
        |> put_items(items)
        |> Params.put_present("payer", payer)

      {:ok, body}
    end
  end

  defp normalize_method(nil), do: nil
  defp normalize_method(method), do: to_string(method)

  defp normalize_payer(nil), do: nil

  defp normalize_payer(payer) when is_map(payer) do
    payer = Params.stringify_keys(payer)

    case Map.get(payer, "address") do
      %{} = address -> Map.put(payer, "address", Params.stringify_keys(address))
      _other -> payer
    end
  end

  defp validate_method(nil), do: :ok
  defp validate_method(@bank_slip), do: :ok

  defp validate_method(method) do
    validation_error(
      "method inválido: #{inspect(method)}. O único valor é \"bank_slip\"; cartão é implícito por token, customer_payment_method_id ou customer_id."
    )
  end

  defp validate_payment_means(attrs, method) do
    card_means = Enum.filter(@payment_means, &Params.present?(attrs, &1))

    cond do
      method == @bank_slip and
          (Params.present?(attrs, :token) or Params.present?(attrs, :customer_payment_method_id)) ->
        validation_error(
          "method bank_slip não aceita token nem customer_payment_method_id (\"Não é preenchido se enviar parâmetro token\")."
        )

      Params.present?(attrs, :token) and Params.present?(attrs, :customer_payment_method_id) ->
        validation_error("Informe token ou customer_payment_method_id, não os dois.")

      method == nil and card_means == [] ->
        validation_error(
          "Informe uma forma de pagar: token, customer_payment_method_id, customer_id com cartão padrão ou method bank_slip."
        )

      true ->
        :ok
    end
  end

  defp validate_invoice_inheritance(_attrs, nil), do: :ok

  defp validate_invoice_inheritance(attrs, _invoice_id) do
    cond do
      Params.present?(attrs, :email) ->
        validation_error("email não é preenchido quando invoice_id é enviado.")

      Params.present?(attrs, :items) ->
        validation_error("items são herdados da fatura quando invoice_id é enviado.")

      true ->
        :ok
    end
  end

  defp validate_items(_items, invoice_id) when is_binary(invoice_id), do: :ok

  defp validate_items([], _invoice_id) do
    validation_error("A cobrança precisa de pelo menos um item (ou de invoice_id).")
  end

  defp validate_items(items, _invoice_id) when length(items) > @max_items do
    validation_error("Total máximo de items excedido (#{@max_items}).")
  end

  defp validate_items(items, _invoice_id) do
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
              is_integer(cents),
       do: :ok

  defp validate_item(item) do
    validation_error(
      "Item inválido: #{inspect(item)}. Cada item precisa de description, quantity inteiro positivo e price_cents inteiro (negativo entra como desconto)."
    )
  end

  defp validate_total(nil), do: :ok
  defp validate_total(total_cents) when total_cents >= @minimum_total_cents, do: :ok

  defp validate_total(total_cents) do
    validation_error(
      "O total da cobrança (#{total_cents} centavos, itens menos discount_cents) precisa ser de pelo menos R$ 1,00."
    )
  end

  defp validate_email(_attrs, _payer, invoice_id) when is_binary(invoice_id), do: :ok

  defp validate_email(attrs, payer, _invoice_id) do
    if Params.present?(attrs, :email) or Params.present?(attrs, :customer_id) or
         (is_map(payer) and Params.present?(payer, "email")) do
      :ok
    else
      validation_error("Informe email, customer_id ou payer.email para a cobrança.")
    end
  end

  # Sem fatura e sem cliente, o boleto não tem a quem ser registrado; com um
  # dos dois, a Iugu herda o pagador.
  defp validate_payer(@bank_slip, attrs, payer, nil) do
    if not Params.present?(attrs, :customer_id) and
         not (is_map(payer) and Params.present?(payer, "cpf_cnpj") and
                Params.present?(payer, "name")) do
      validation_error("Boleto exige payer com cpf_cnpj e name (ou invoice_id / customer_id).")
    else
      :ok
    end
  end

  defp validate_payer(_method, _attrs, _payer, _invoice_id), do: :ok

  defp validate_months(nil, _method, _total_cents), do: :ok

  defp validate_months(_months, @bank_slip, _total_cents) do
    validation_error("months não se aplica a boleto.")
  end

  defp validate_months(months, _method, total_cents)
       when is_integer(months) and months in @installments do
    if is_integer(total_cents) and div(total_cents, months) < @minimum_installment_cents do
      validation_error(
        "Parcela mínima de R$ 5,00: #{total_cents} centavos em #{months} parcelas fica abaixo disso."
      )
    else
      :ok
    end
  end

  defp validate_months(months, _method, _total_cents) do
    validation_error(
      "months inválido: #{inspect(months)}. Use um inteiro de 2 a 12; à vista, omita."
    )
  end

  defp items_total_cents(items, attrs) do
    Enum.reduce(items, 0, fn item, total ->
      quantity = Map.get(item, "quantity")
      price_cents = Map.get(item, "price_cents")

      if is_integer(quantity) and is_integer(price_cents),
        do: total + quantity * price_cents,
        else: total
    end) - (Map.get(attrs, :discount_cents) || 0)
  end

  defp put_items(body, []), do: body
  defp put_items(body, items), do: Map.put(body, "items", items)

  defp read_outcome(%{"success" => true} = response, _path), do: {:ok, response}

  defp read_outcome(%{"success" => false} = response, path) do
    {:error,
     Error.declined(response, path,
       lr: Response.get_any(response, ["LR", "lr"]),
       message: decline_message(response)
     )}
  end

  defp read_outcome(response, path) do
    {:error,
     %Error{kind: :unexpected, path: path, body: response, messages: ["resposta sem success"]}}
  end

  # O texto do adquirente está em message; info_message e um mapa errors não
  # vazio são os fallbacks, já que o formato da recusa não é documentado.
  defp decline_message(response) do
    Enum.find_value(["message", "info_message"], fn key ->
      case Map.get(response, key) do
        text when is_binary(text) and text != "" -> text
        _other -> nil
      end
    end) || errors_message(Map.get(response, "errors"))
  end

  defp errors_message(errors) when is_binary(errors) and errors != "", do: errors

  defp errors_message(%{} = errors) when map_size(errors) > 0 do
    errors
    |> Enum.sort()
    |> Enum.map_join("; ", fn {field, messages} ->
      "#{field}: #{messages |> List.wrap() |> Enum.join(", ")}"
    end)
  end

  defp errors_message(_errors), do: nil

  defp build_two_cards_legs(payments) when length(payments) != 2 do
    {:error,
     Error.validation(
       "A cobrança com dois cartões leva exatamente dois pagamentos.",
       @two_cards_path
     )}
  end

  defp build_two_cards_legs(payments) do
    legs = Enum.map(payments, &Params.stringify_keys/1)

    if Enum.all?(legs, &valid_leg?/1) do
      {:ok,
       Enum.map(legs, fn leg ->
         %{"token" => Map.get(leg, "token"), "amount" => Map.get(leg, "amount_cents")}
       end)}
    else
      {:error,
       Error.validation(
         "Cada pagamento precisa de token (string) e amount_cents (inteiro positivo).",
         @two_cards_path
       )}
    end
  end

  defp valid_leg?(%{"token" => token, "amount_cents" => amount_cents})
       when is_binary(token) and token != "" and is_integer(amount_cents) and amount_cents > 0,
       do: true

  defp valid_leg?(_leg), do: false

  defp read_two_cards_outcome(%{"credit_card_transactions" => transactions} = response)
       when is_list(transactions) do
    case Enum.find(transactions, &(Map.get(&1, "success") != true)) do
      nil ->
        {:ok,
         %{
           invoice_status: get_in(response, ["invoice", "status"]),
           transactions: transactions,
           body: response
         }}

      declined ->
        {:error,
         Error.declined(response, @two_cards_path,
           lr: Response.get_any(declined, ["LR", "lr"]),
           message: decline_message(declined)
         )}
    end
  end

  defp read_two_cards_outcome(response) do
    {:error,
     %Error{
       kind: :unexpected,
       path: @two_cards_path,
       body: response,
       messages: ["resposta sem credit_card_transactions"]
     }}
  end

  defp transaction_params(filter_opts) do
    params =
      filter_opts
      |> Pagination.params(@max_limit)
      |> Params.put_present(:status, Keyword.get(filter_opts, :status))

    Enum.reduce(@datetime_filters, params, fn filter, params ->
      Params.put_present(
        params,
        filter,
        filter_opts |> Keyword.get(filter) |> Params.format_local_datetime()
      )
    end)
  end

  defp validation_error(message), do: {:error, Error.validation(message, @path)}

  defp stringify_or_nil(nil), do: nil
  defp stringify_or_nil(value), do: to_string(value)
end
