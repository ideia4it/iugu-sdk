defmodule Iugu.FinancialStatement do
  @moduledoc """
  Relatórios para conciliação: extrato financeiro, extrato de faturas,
  extrato consolidado, liquidados e recebíveis consolidados.

  São cinco leituras da mesma conta, cada uma com um recorte:

    * `financial/1`: cada lançamento (crédito e débito) com o saldo depois
      dele. É onde uma transferência entre contas aparece
      (`reference_type: "Transfer"`) e onde se confere o que o saque em
      trânsito deixou de saldo
    * `invoices_statement/1`: uma linha por fatura do mês, com o que foi pago,
      o que falta, a taxa e a comissão
    * `consolidated/1`: uma linha por tipo de movimento por dia
      (`movement_type`), com saldo inicial e final do dia
    * `settled/1`: o que a Iugu liquidou num dia, por bandeira
      (`transaction_code`), separando pagamentos para a própria conta e para
      destino externo
    * `receivables/1`: os recebíveis de cartão agrupados por data de
      liquidação e bandeira, com os baldes `pending`, `done`, `canceled`,
      `booked` e `total`

  Nenhuma exige assinatura RSA; todas são GET com retry em falha transitória.

  ## Qual token

  O extrato é o da conta que autentica: não há `account_id` na rota. Para o
  extrato da mestre, o token padrão do SDK; para o de uma subconta, o
  `live_api_token` dela em `api_token:`. A referência diz que
  `financial/1`, `consolidated/1`, `settled/1` e `receivables/1` "obrigam a
  utilização do `live_api_token`" ("Somente em modo produção há movimentação
  de saldo na conta iugu"); a página gêmea do BaaS tolera o `test_api_token`
  no extrato financeiro. Se a mestre consegue ler o extrato de uma subconta
  por parâmetro **não está documentado**.

  ## Dinheiro vem em três formas

  Os extratos são a parte menos uniforme da API. `financial/1` escreve
  `amount` formatado (`"R$ 1,00"`, conforme `hl`) e `amount_cents` como
  string com uma casa (`"100.0"`); `invoices_statement/1` escreve
  `"40.00 BRL"`; `consolidated/1` escreve `total_amount` como decimal em
  reais (`"2.59"`) e `total_amount_cents` às vezes `null`; `settled/1` e
  `receivables/1` escrevem inteiros em centavos de verdade. Os mapas
  normalizados trazem sempre `*_cents` inteiro, lendo `amount_cents` quando
  ele existe e caindo para `Iugu.Money.parse_brl/1` ou
  `parse_reais/1` quando não; o que não deu para ler vira `nil`, nunca zero.
  O corpo cru fica em `body` para o dia em que a Iugu mudar o formato.

  ## Período

  `financial/1` recebe `year`, `month` e `day` como filtros opcionais e
  pagina com `start`/`limit` (até 1.000, "embora recomendamos usar no máximo
  limit=100"); `transactions_total` é o total do período, e é este o total
  que vale para paginar. O período padrão sem filtro **não está
  documentado** (o exemplo devolve do último dia do mês anterior até agora).

  `consolidated/1` exige os três, e `day` não é um dia só: "Se informa o dia
  07, a requisição vai trazer todas as entradas do dia 07 até o último dia do
  mês." Por isso a opção se chama `:from`. `settled/1` recebe `date`, que
  "precisa ser menor ou igual ao dia anterior". `receivables/1` filtra por
  `scheduled_date_from`/`scheduled_date_to`, a data prevista de liquidação.

  ## O que não está confirmado

    * o vocabulário de `transaction_type` e `reference_type` no extrato
      financeiro (só `misc`, `Invoice` e `Transfer` aparecem; os tipos de
      `movement_types/0` são a lista provável)
    * o envelope dos 400 (`mon out of range`, `mday out of range`; a
      documentação mostra `{}`)
    * se `date` é obrigatório em `settled/1` (o SDK exige) e a forma dos itens
      de `transactions` ali (esquema vazio)
    * se o extrato de faturas aceita o `test_api_token`
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Money
  alias Iugu.Pagination
  alias Iugu.Params
  alias Iugu.Response

  @financial_path "/v1/accounts/financial"
  @invoices_path "/v1/accounts/invoices"
  @consolidated_path "/v1/accounts/consolidated_statements"
  @settled_path "/v1/accounts/financial/settled"
  @receivables_path "/v1/accounts/consolidated_receivables"

  @financial_max_limit 1_000
  @locales ["en", "pt-BR"]
  @financial_filters [:year, :month, :day, :start, :limit, :locale]
  @invoice_statuses [
    "pending",
    "paid",
    "partially_paid",
    "externally_paid",
    "refunded",
    "expired",
    "canceled",
    "in_protest",
    "chargeback"
  ]
  @movement_types %{
    "transfer_ted" => "TED",
    "transfer_pix" => "Transferência Pix",
    "transfer_ted_revenue" => "Tarifa de TED",
    "transfer_pix_revenue" => "Tarifa de Transferência Pix",
    "invoice_return" => "Liquidação de Cartão",
    "invoice_return_revenue" => "Tarifa de Liquidação de Cartão",
    "invoice_return_advanced" => "Antecipação de Recebíveis",
    "invoice_return_advanced_revenue" => "Tarifa de Liquidação Antecipada",
    "refund" => "Estorno de Cartão",
    "pix_refund" => "Estorno de Pix",
    "pix_refund_revert" => "Reversão Estorno Pix",
    "pix" => "Liquidação de Pix",
    "pix_revenue" => "Tarifa de Liquidação de Pix",
    "bank_slip" => "Liquidação de Boleto",
    "bank_slip_return" => "Liquidação de Boleto Final de Semana",
    "bank_slip_revenue" => "Tarifa de Liquidação de Boleto",
    "account_transfer" => "Transferência entre Contas",
    "billing" => "Cobrança iugu",
    "withdraw" => "Saque",
    "start_balance" => "Saldo Inicial",
    "end_balance" => "Saldo Final",
    "chargeback" => "Chargeback",
    "receivable_unit_settlement" => "Liquidação Residual de Recebíveis",
    "account_transfer_in" => "Transferência entre contas (Entrada)",
    "account_transfer_out" => "Transferência entre contas (Saída)",
    "advance" => "Tarifa de Antecipação",
    "misc" => "Outros",
    "deposit" => "Depósito",
    "payment" => "Pagamento de Contas"
  }
  @transaction_codes %{
    "VCC" => "visa",
    "ECC" => "elo",
    "DBC" => "discover",
    "CBC" => "cabal",
    "ACC" => "amex",
    "HCC" => "hipercard",
    "MCC" => "mastercard",
    "DCC" => "diners",
    "SCC" => "sorocred",
    "BCC" => "banescard",
    "GCC" => "goodcard",
    "JCC" => "jcb",
    "VDC" => "verdecard",
    "AGC" => "agiplan",
    "RCC" => "redesplan",
    "AVC" => "avista",
    "MAC" => "mais",
    "CUP" => "cup",
    "CSC" => "credi_shop",
    "DAC" => "dacasa",
    "AUC" => "aura",
    "CZC" => "credz",
    "FRC" => "fortbrasil",
    "MXC" => "maxifrota",
    "SFC" => "senff",
    "TKC" => "ticketlog",
    "BNC" => "banesecard",
    "CCD" => "calcard",
    "BRC" => "brasil_card",
    "SPC" => "sem_parar",
    "CAC" => "cielo_amex"
  }

  @type transaction :: %{
          type: String.t() | nil,
          amount_cents: integer() | nil,
          balance_cents: integer() | nil,
          description: String.t() | nil,
          entry_date: String.t() | nil,
          reference: String.t() | nil,
          reference_type: String.t() | nil,
          transaction_type: String.t() | nil,
          account_id: String.t() | nil,
          invoice_email: String.t() | nil,
          customer_name: String.t() | nil,
          customer_ref: String.t() | nil,
          payer_name: String.t() | nil,
          body: map()
        }

  @type financial :: %{
          transactions: [transaction()],
          initial_balance_cents: integer() | nil,
          initial_balance_date: String.t() | nil,
          initial_date: String.t() | nil,
          final_date: String.t() | nil,
          transactions_total: integer() | nil,
          page_info: Pagination.page_info(),
          body: map()
        }

  @type invoice_line :: %{
          id: String.t() | nil,
          status: String.t() | nil,
          created_at: String.t() | nil,
          due_date: String.t() | nil,
          paid_at: String.t() | nil,
          refunded_at: String.t() | nil,
          payment_method: String.t() | nil,
          installments: integer() | nil,
          customer_id: String.t() | nil,
          customer_email: String.t() | nil,
          customer_name: String.t() | nil,
          subscription_id: String.t() | nil,
          receivable_date: String.t() | nil,
          receivable_reference: String.t() | nil,
          receivable_total_cents: integer() | nil,
          pending_value_cents: integer() | nil,
          paid_value_cents: integer() | nil,
          taxes_paid_cents: integer() | nil,
          commission_cents: integer() | nil,
          body: map()
        }

  @type consolidated_row :: %{
          id: integer() | nil,
          account_id: String.t() | nil,
          movement_type: String.t() | nil,
          entry_date: String.t() | nil,
          total_amount_cents: integer() | nil,
          entries_count: integer() | nil,
          entry_order: integer() | nil,
          body: map()
        }

  @type settled :: %{
          date: String.t() | nil,
          total_transactions_amount_cents: integer() | nil,
          total_payments_amount_cents: integer() | nil,
          transactions: [map()],
          payments: %{self: [map()], external: [map()]},
          body: map()
        }

  @doc """
  Extrato financeiro: os lançamentos do período com o saldo após cada um.

  `GET /v1/accounts/financial`, token da conta em `api_token:`. Opções:
  `:year`, `:month` (1 a 12) e `:day` (1 a 31) como inteiros ou strings,
  `:start`, `:limit` (preso a 1.000) e `:locale` (`"en"` ou `"pt-BR"`, o
  `hl` da rota, que só muda o texto de `amount`). Mês ou dia fora da faixa
  volta como erro de validação sem ir à Iugu.

  A resposta traz `transactions` normalizadas (`type` em `credit`/`debit`,
  `amount_cents` e `balance_cents` inteiros, o saldo depois do lançamento),
  `initial_balance_cents` com `initial_balance_date`, `initial_date`,
  `final_date`, `transactions_total` (o total do período, para paginar) e
  `page_info`.
  """
  @spec financial(keyword()) :: {:ok, financial()} | {:error, Error.t()}
  def financial(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, @financial_filters)

    with :ok <- validate_range(Keyword.get(filter_opts, :month), 1..12, "month", @financial_path),
         :ok <- validate_range(Keyword.get(filter_opts, :day), 1..31, "day", @financial_path),
         :ok <-
           Params.validate_member(
             Keyword.get(filter_opts, :locale),
             @locales,
             "locale",
             @financial_path
           ),
         params = financial_params(filter_opts),
         {:ok, body} <- Client.get(@financial_path, Keyword.put(req_opts, :params, params)) do
      {:ok, normalize_financial(body, params)}
    end
  end

  @doc """
  Percorre todas as páginas de `financial/1` com os mesmos filtros,
  devolvendo os lançamentos normalizados.

  Página de 100 por padrão (o que a Iugu recomenda), até 1.000. Para na
  primeira página menor que `limit` e levanta o `Iugu.Error` da
  primeira página que falhar.
  """
  @spec stream_financial(keyword()) :: Enumerable.t()
  def stream_financial(opts \\ []) do
    {page_opts, other_opts} = Keyword.split(opts, [:start, :limit])

    Pagination.stream(
      fn stream_page_opts ->
        with {:ok, statement} <- financial(Keyword.merge(other_opts, stream_page_opts)) do
          {:ok, statement.transactions}
        end
      end,
      ["items"],
      Keyword.merge([limit: 100, max_limit: @financial_max_limit], page_opts)
    )
  end

  @doc """
  Extrato de faturas: uma linha por fatura do mês.

  `GET /v1/accounts/invoices`, token da conta em `api_token:`. Opções:
  `:year`, `:month` e `:status` (um de `invoice_statuses/0`). A rota não
  pagina. A resposta é um array cru; cada linha vem normalizada com
  `pending_value_cents`, `paid_value_cents`, `taxes_paid_cents`,
  `commission_cents` e `receivable_total_cents` inteiros lidos de
  `"40.00 BRL"`.
  """
  @spec invoices_statement(keyword()) :: {:ok, [invoice_line()]} | {:error, Error.t()}
  def invoices_statement(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, [:year, :month, :status])

    with :ok <- validate_range(Keyword.get(filter_opts, :month), 1..12, "month", @invoices_path),
         :ok <-
           Params.validate_member(
             Keyword.get(filter_opts, :status),
             @invoice_statuses,
             "status",
             @invoices_path
           ),
         params = present_params(filter_opts, [:year, :month, :status]),
         {:ok, body} <- Client.get(@invoices_path, Keyword.put(req_opts, :params, params)) do
      {:ok, body |> Response.items() |> Enum.map(&normalize_invoice_line/1)}
    end
  end

  @doc """
  Extrato consolidado: uma linha por tipo de movimento por dia, de `from`
  até o fim do mês.

  `GET /v1/accounts/consolidated_statements`, `live_api_token` da conta em
  `api_token:`. `from` é um `Date`; a Iugu recebe `year`, `month` e `day` e
  devolve "todas as entradas do dia informado até o último dia do mês".
  Cada linha traz `movement_type` (um de `movement_types/0`; `start_balance`
  abre o dia com `entry_order` 0 e `end_balance` o fecha com 30),
  `total_amount_cents` inteiro (lido de `total_amount_cents` ou, quando ele
  vem `null`, de `total_amount` em reais) e `entries_count`.
  """
  @spec consolidated(Date.t(), keyword()) :: {:ok, [consolidated_row()]} | {:error, Error.t()}
  def consolidated(%Date{} = from, opts \\ []) do
    params = %{year: from.year, month: from.month, day: from.day}

    with {:ok, body} <- Client.get(@consolidated_path, Keyword.put(opts, :params, params)) do
      {:ok,
       body
       |> Response.items(["consolidated_statements"])
       |> Enum.map(&normalize_consolidated_row/1)}
    end
  end

  @doc """
  Liquidados de um dia, por bandeira.

  `GET /v1/accounts/financial/settled`, `live_api_token` da conta em
  `api_token:` ("Apenas disponível para o ambiente produção"). `date` é um
  `Date` de ontem para trás ("precisa ser menor ou igual ao dia anterior");
  hoje ou depois volta como erro de validação sem ir à Iugu. "Hoje" é o dia
  em São Paulo (`Iugu.Params.local_today/0`), não o UTC: entre 21h
  e meia-noite os dois divergem e a Iugu fecha o dia no horário local.

  A resposta traz `total_transactions_amount_cents`,
  `total_payments_amount_cents`, `transactions` (forma não documentada,
  repassada) e `payments` com `self` (liquidação na própria conta) e
  `external` (liquidação em destino externo, com `destination_document`,
  `destination_branch` e `destination_account`); cada pagamento tem
  `amount_cents` inteiro e `transaction_code`, a bandeira
  (`card_brand/1`).
  """
  @spec settled(Date.t(), keyword()) :: {:ok, settled()} | {:error, Error.t()}
  def settled(%Date{} = date, opts \\ []) do
    with :ok <- validate_settled_date(date),
         {:ok, body} <-
           Client.get(@settled_path, Keyword.put(opts, :params, %{date: Date.to_iso8601(date)})) do
      {:ok, normalize_settled(body)}
    end
  end

  @doc """
  Recebíveis de cartão consolidados por data de liquidação e bandeira.

  `GET /v1/accounts/consolidated_receivables`, `live_api_token` da conta em
  `api_token:`. Opções: `:scheduled_date_from` e `:scheduled_date_to`
  (`Date`), a janela da data prevista de liquidação.

  Cada linha já vem em centavos inteiros, nos baldes `pending_*`, `done_*`,
  `canceled_*`, `booked_*` e `total_*` (`amount`, `client_share`, `fee`,
  `split`, `advance_fee`, `count`), mais os de chargeback. A Iugu escreve a
  chave `amount_availableble_for_advance_today_cents` com esse erro de
  grafia; a linha volta como veio e ganha a cópia
  `amount_available_for_advance_today_cents`.
  """
  @spec receivables(keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def receivables(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, [:scheduled_date_from, :scheduled_date_to])

    params =
      filter_opts
      |> Enum.map(fn {key, value} -> {key, Params.format_date(value)} end)
      |> present_params([:scheduled_date_from, :scheduled_date_to])

    with {:ok, body} <- Client.get(@receivables_path, Keyword.put(req_opts, :params, params)) do
      {:ok,
       body
       |> Response.items(["consolidated_receivables"])
       |> Enum.map(&normalize_receivable_row/1)}
    end
  end

  @doc "Os status aceitos no filtro de `invoices_statement/1`."
  @spec invoice_statuses() :: [String.t()]
  def invoice_statuses, do: @invoice_statuses

  @doc "Os tipos de movimento do extrato consolidado, em ordem alfabética."
  @spec movement_types() :: [String.t()]
  def movement_types, do: @movement_types |> Map.keys() |> Enum.sort()

  @doc """
  Descrição em pt-BR de um `movement_type`, como na documentação.

      iex> Iugu.FinancialStatement.movement_type_description("withdraw")
      "Saque"

      iex> Iugu.FinancialStatement.movement_type_description("novo")
      nil
  """
  @spec movement_type_description(String.t() | nil) :: String.t() | nil
  def movement_type_description(movement_type), do: Map.get(@movement_types, movement_type)

  @doc """
  Bandeira de um `transaction_code` dos liquidados e dos recebíveis.

      iex> Iugu.FinancialStatement.card_brand("MCC")
      "mastercard"

      iex> Iugu.FinancialStatement.card_brand("XXX")
      nil
  """
  @spec card_brand(String.t() | nil) :: String.t() | nil
  def card_brand(transaction_code), do: Map.get(@transaction_codes, transaction_code)

  defp normalize_financial(body, params) do
    initial_balance = Map.get(body, "initial_balance") || %{}

    %{
      transactions:
        body |> Response.items(["transactions"]) |> Enum.map(&normalize_transaction/1),
      initial_balance_cents: money_cents(initial_balance, "amount"),
      initial_balance_date: Map.get(initial_balance, "entry_date"),
      initial_date: Map.get(body, "initial_date"),
      final_date: Map.get(body, "final_date"),
      transactions_total: Response.integer(body, ["transactions_total"]),
      page_info:
        Pagination.page_info(body,
          start: Map.get(params, :start, 0),
          limit: Map.get(params, :limit)
        ),
      body: body
    }
  end

  defp normalize_transaction(body) when is_map(body) do
    %{
      type: Map.get(body, "type"),
      amount_cents: money_cents(body, "amount"),
      balance_cents: money_cents(body, "balance"),
      description: Map.get(body, "description"),
      entry_date: Map.get(body, "entry_date"),
      reference: Map.get(body, "reference"),
      reference_type: Map.get(body, "reference_type"),
      transaction_type: Map.get(body, "transaction_type"),
      account_id: Map.get(body, "account_id"),
      invoice_email: Map.get(body, "invoice_email"),
      customer_name: Map.get(body, "customer_name"),
      customer_ref: Map.get(body, "customer_ref"),
      payer_name: Map.get(body, "payer_name"),
      body: body
    }
  end

  defp normalize_invoice_line(body) when is_map(body) do
    %{
      id: Map.get(body, "id"),
      status: Map.get(body, "status"),
      created_at: Map.get(body, "created_at"),
      due_date: Map.get(body, "due_date"),
      paid_at: Map.get(body, "paid_at"),
      refunded_at: Map.get(body, "refunded_at"),
      payment_method: Map.get(body, "payment_method"),
      installments: Response.integer(body, ["installments"]),
      customer_id: Map.get(body, "customer_id"),
      customer_email: Map.get(body, "customer_email"),
      customer_name: Map.get(body, "customer_name"),
      subscription_id: Map.get(body, "subscription_id"),
      receivable_date: Map.get(body, "receivable_date"),
      receivable_reference: Map.get(body, "receivable_reference"),
      receivable_total_cents: reais_cents(Map.get(body, "receivable_total")),
      pending_value_cents: reais_cents(Map.get(body, "pending_value")),
      paid_value_cents: reais_cents(Map.get(body, "paid_value")),
      taxes_paid_cents: reais_cents(Map.get(body, "taxes_paid")),
      commission_cents: reais_cents(Map.get(body, "commission")),
      body: body
    }
  end

  defp normalize_consolidated_row(body) when is_map(body) do
    %{
      id: Response.integer(body, ["id"]),
      account_id: Map.get(body, "account_id"),
      movement_type: Map.get(body, "movement_type"),
      entry_date: Map.get(body, "entry_date"),
      total_amount_cents: money_cents(body, "total_amount"),
      entries_count: Response.integer(body, ["entries_count"]),
      entry_order: Response.integer(body, ["entry_order"]),
      body: body
    }
  end

  defp normalize_settled(body) when is_map(body) do
    payments = Map.get(body, "payments") || %{}

    %{
      date: Map.get(body, "date"),
      total_transactions_amount_cents: Response.integer(body, ["total_transactions_amount"]),
      total_payments_amount_cents: Response.integer(body, ["total_payments_amount"]),
      transactions: Response.items(body, ["transactions"]),
      payments: %{
        self: Response.items(payments, ["self"]),
        external: Response.items(payments, ["external"])
      },
      body: body
    }
  end

  defp normalize_receivable_row(body) when is_map(body) do
    Map.put_new(
      body,
      "amount_available_for_advance_today_cents",
      Map.get(body, "amount_availableble_for_advance_today_cents")
    )
  end

  # `<field>_cents` é o inteiro de referência quando a linha o carrega (mesmo
  # como "100.0"); o `<field>` formatado é o fallback, seja qual for dos dois
  # formatos que a rota escreve.
  defp money_cents(body, field) do
    case Response.integer(body, [field <> "_cents"]) do
      nil -> body |> Map.get(field) |> formatted_cents()
      cents -> cents
    end
  end

  defp formatted_cents(value) do
    with :error <- Money.parse_brl(value),
         :error <- Money.parse_reais(value) do
      nil
    else
      {:ok, cents} -> cents
    end
  end

  defp reais_cents(value) do
    case Money.parse_reais(value) do
      {:ok, cents} -> cents
      :error -> nil
    end
  end

  defp financial_params(filter_opts) do
    filter_opts
    |> Pagination.params(@financial_max_limit)
    |> Params.put_present(:year, Keyword.get(filter_opts, :year))
    |> Params.put_present(:month, Keyword.get(filter_opts, :month))
    |> Params.put_present(:day, Keyword.get(filter_opts, :day))
    |> Params.put_present(:hl, Keyword.get(filter_opts, :locale))
  end

  defp present_params(opts, keys) do
    Enum.reduce(keys, %{}, fn key, params ->
      Params.put_present(params, key, Keyword.get(opts, key))
    end)
  end

  defp validate_range(nil, _range, _field, _path), do: :ok

  defp validate_range(value, range, field, path) do
    integer =
      case value do
        value when is_integer(value) -> value
        value when is_binary(value) -> value |> Integer.parse() |> parsed_integer()
        _other -> nil
      end

    if integer in range do
      :ok
    else
      {:error,
       Error.validation(
         "#{field} inválido: #{inspect(value)}. Use um inteiro de #{range.first} a #{range.last}.",
         path
       )}
    end
  end

  defp parsed_integer({integer, ""}), do: integer
  defp parsed_integer(_other), do: nil

  defp validate_settled_date(date) do
    if Date.compare(date, Params.local_today()) == :lt do
      :ok
    else
      {:error,
       Error.validation(
         "date dos liquidados precisa ser ontem ou antes; a Iugu não consolida o dia corrente.",
         @settled_path
       )}
    end
  end
end
