defmodule Iugu.Split do
  @moduledoc """
  Regra de split: quanto de uma fatura vai para outra conta Iugu.

  "O split é a divisão de valores de uma transação entre uma ou mais contas",
  sempre entre a conta mestre e as subcontas do mesmo marketplace. A mesma
  regra aparece em três lugares, e este módulo é a representação única dela:

    * **split padrão da conta**: vale para toda fatura futura da conta que o
      configura. Lê-se com `current/1` e grava-se com `set_default/2`
      (`POST /v1/splits`), com `Iugu.Account.configure/2`
      (`splits`, assinado) ou na criação da subconta em
      `Iugu.Marketplace.create_account/2`
    * **split por fatura**: `:splits` em `Iugu.Invoice.create/2`,
      "alternativa ao Split Padrão da Conta" para aquela fatura
    * **split por assinatura**: `splits` em `POST /v1/subscriptions`, copiado
      para toda fatura da assinatura no momento da criação

  O que este módulo conhece são as regras; a subconta que recebe fica em
  `Iugu.Account`, e quem cria a fatura em `Iugu.Invoice`.

  ## Quem cria paga a taxa, e o resto fica com quem cria

  "O split é liquidado sempre na conta que está criando a transação, ou
  seja, a conta que cria a transação paga as taxas iugu e visualiza a
  transação no painel." Numa fatura de R$ 100,00 com taxa de R$ 2,50 e 70%
  para a subconta, a mestre que criou recebe R$ 27,50 e a subconta R$ 70,00;
  se a subconta criou, ela fica com R$ 67,50 e a mestre com R$ 30,00. Não
  existe regra para a própria conta criadora: ela recebe o que sobra. Daí as
  duas regras que `validate/2` confere antes de gastar a chamada:

    * "**Nunca** insira o `account_id` da conta criadora da Fatura." A Iugu
      responde 422 `Conta do destinatário não pode ser a conta atual`
    * "A soma dos Splits **nunca** deve totalizar 100% do valor da fatura;
      caso contrário, a divisão entre as contas **não será processada**, e,
      quando a invoice for paga, o valor **total** será destinado à conta
      criadora." É uma falha **silenciosa**: a API aceita e o dinheiro não se
      divide

  Os destinatários precisam estar verificados e no mesmo marketplace
  ("Conta do destinatário deve estar no mesmo contexto"), sem repetição
  ("Conta do destinatário com duplicidade").

  ## Centavos, percentual e os dois juntos

  `cents` é valor fixo em centavos da fatura; `percent` é "porcentagem do
  **valor total** da fatura", com decimais (`1.5`). Os dois na mesma regra só
  com `permit_aggregated: true`; sem isso a Iugu responde 422 `Split deve ter
  valor em centavos ou em percentual`. Quando agregados, "é executado
  primeiro o percentual e depois o valor fixo, para então somar o valor final
  da regra".

  Há variantes por forma de pagamento (`pix_cents`, `pix_percent`,
  `bank_slip_*`, `credit_card_*`), que só valem quando a fatura é paga
  daquele jeito, e por número de parcelas (`credit_card_1x_cents` até
  `credit_card_12x_cents`, e até 18x nas respostas de contas antigas), que
  só valem quando o cartão é parcelado exatamente naquele número. A
  precedência entre campo genérico, por forma e por parcela **não está
  documentada**; `total_cents/3` soma o que se aplica e, sem saber a forma
  de pagamento, estima o pior caso.

  ## O split padrão substitui, não acrescenta

  "Criar um novo multi split sobrepõe o que já está configurado. Todas as
  faturas em aberto em uma conta irão acatar a nova regra de split criada."
  `set_default/2` manda a lista completa a cada chamada. Como remover o split
  padrão **não está documentado** (nenhuma rota de exclusão existe; uma lista
  vazia é a aposta natural, confirme contra a conta).

  ## O que não está confirmado

    * se o `splits` de uma fatura substitui ou se soma ao split padrão da
      conta; a documentação chama de "alternativa", o que sugere substituir
    * qual token `POST /v1/splits` e `GET /v1/splits/current` aceitam além de
      "`api_token`" (assumido: o `live_api_token` ou `test_api_token` da conta
      configurada), e o que `current/1` devolve sem split configurado (404 ou
      `split_rules` vazio)
    * o arredondamento que a Iugu aplica ao percentual; `total_cents/3`
      arredonda meio para cima
    * o significado dos `percent` decimais nas respostas (`0.09`)
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Params
  alias Iugu.Response

  @splits_path "/v1/splits"
  @current_path "/v1/splits/current"

  @payment_methods ["credit_card", "bank_slip", "pix"]
  @max_installments 18

  # Resolvido uma vez aqui para que nenhum código de tempo de execução
  # construa átomos a partir de uma string.
  @method_amount_fields Map.new(@payment_methods, fn method ->
                          {method, {:"#{method}_cents", :"#{method}_percent"}}
                        end)

  @method_fields Enum.flat_map(@payment_methods, fn method ->
                   Tuple.to_list(Map.fetch!(@method_amount_fields, method))
                 end)

  @installment_fields Enum.flat_map(1..@max_installments, fn installments ->
                        [
                          :"credit_card_#{installments}x_cents",
                          :"credit_card_#{installments}x_percent"
                        ]
                      end)

  @amount_fields [:cents, :percent] ++ @method_fields ++ @installment_fields
  @fields [:recipient_account_id, :permit_aggregated | @amount_fields]

  @type t :: %__MODULE__{
          id: String.t() | nil,
          split_id: String.t() | nil,
          recipient_account_id: String.t(),
          cents: non_neg_integer() | nil,
          percent: number() | nil,
          permit_aggregated: boolean() | nil,
          credit_card_cents: non_neg_integer() | nil,
          credit_card_percent: number() | nil,
          bank_slip_cents: non_neg_integer() | nil,
          bank_slip_percent: number() | nil,
          pix_cents: non_neg_integer() | nil,
          pix_percent: number() | nil,
          installments: %{
            optional(pos_integer()) => %{cents: integer() | nil, percent: number() | nil}
          }
        }

  @type default_split :: %{
          id: String.t() | nil,
          account_id: String.t() | nil,
          split_rules: [t()],
          body: map()
        }

  @enforce_keys [:recipient_account_id]
  defstruct [
    :id,
    :split_id,
    :recipient_account_id,
    :cents,
    :percent,
    :permit_aggregated,
    :credit_card_cents,
    :credit_card_percent,
    :bank_slip_cents,
    :bank_slip_percent,
    :pix_cents,
    :pix_percent,
    installments: %{}
  ]

  @doc "Valor fixo em centavos da fatura para a conta destinatária."
  @spec fixed(String.t(), pos_integer()) :: t()
  def fixed(recipient_account_id, cents)
      when is_binary(recipient_account_id) and is_integer(cents) do
    %__MODULE__{recipient_account_id: recipient_account_id, cents: cents}
  end

  @doc "Percentual do total da fatura para a conta destinatária. Aceita decimais (`1.5`)."
  @spec percent(String.t(), number()) :: t()
  def percent(recipient_account_id, percent)
      when is_binary(recipient_account_id) and is_number(percent) do
    %__MODULE__{recipient_account_id: recipient_account_id, percent: percent}
  end

  @doc """
  Percentual mais valor fixo na mesma regra, já com `permit_aggregated: true`.

  É a forma que a receita oficial mostra para agregar; sem o flag a Iugu
  recusa a regra com 422.
  """
  @spec aggregated(String.t(), pos_integer(), number()) :: t()
  def aggregated(recipient_account_id, cents, percent)
      when is_binary(recipient_account_id) and is_integer(cents) and is_number(percent) do
    %__MODULE__{
      recipient_account_id: recipient_account_id,
      cents: cents,
      percent: percent,
      permit_aggregated: true
    }
  end

  @doc """
  Regra com qualquer combinação de campos, no vocabulário da API.

  Aceita mapa ou keyword com chaves em átomo ou string: `recipient_account_id`
  (obrigatório), `cents`, `percent`, `permit_aggregated`, `pix_cents`,
  `pix_percent`, `bank_slip_cents`, `bank_slip_percent`, `credit_card_cents`,
  `credit_card_percent` e `credit_card_1x_cents` ... `credit_card_18x_percent`.
  Os campos por parcela viram o mapa `installments`
  (`%{1 => %{cents: 20, percent: nil}}`). Uma chave fora dessa lista é erro de
  programação e levanta `ArgumentError`.

      iex> Iugu.Split.new(%{recipient_account_id: "ACC", permit_aggregated: true, pix_cents: 499, pix_percent: 4})
      %Iugu.Split{recipient_account_id: "ACC", permit_aggregated: true, pix_cents: 499, pix_percent: 4}

      iex> Iugu.Split.new(recipient_account_id: "ACC", credit_card_3x_cents: 20)
      %Iugu.Split{recipient_account_id: "ACC", installments: %{3 => %{cents: 20, percent: nil}}}
  """
  @spec new(map() | keyword()) :: t()
  def new(attrs) when is_list(attrs) or is_map(attrs) do
    attrs = Map.new(attrs, fn {key, value} -> {Params.field!(key, @fields, "split"), value} end)

    Enum.reduce(attrs, %__MODULE__{recipient_account_id: fetch_recipient!(attrs)}, fn
      {:recipient_account_id, _value}, split ->
        split

      {field, value}, split when field in @installment_fields ->
        put_installment(split, field, value)

      {field, value}, split ->
        Map.put(split, field, value)
    end)
  end

  @doc "Formas de pagamento com campos próprios de split."
  @spec payment_methods() :: [String.t()]
  def payment_methods, do: @payment_methods

  @doc """
  Converte a lista de regras para o formato da API, só com os campos
  preenchidos.

  Os valores em centavos saem como inteiros e os percentuais como números,
  mesmo onde a receita oficial mostra string (`"cents": "499"`).

      iex> Iugu.Split.to_params([Iugu.Split.aggregated("ACC", 499, 4)])
      [%{"recipient_account_id" => "ACC", "cents" => 499, "percent" => 4, "permit_aggregated" => true}]
  """
  @spec to_params([t()]) :: [map()]
  def to_params(splits) when is_list(splits), do: Enum.map(splits, &to_param/1)

  @doc """
  Lê as regras de volta de uma resposta da Iugu.

  Aceita a lista crua, o corpo de `POST /v1/splits` e `GET /v1/splits/current`
  (`split_rules`), o de uma fatura (`split_rules`) e o de uma conta
  (`splits`). Números que vierem como string são convertidos; um campo
  ausente, `null` ou `0` vira `nil`, porque a resposta de conta escreve
  `"cents": 0, "percent": 0` nos campos que não foram configurados e as
  outras rotas escrevem `null` para a mesma coisa. O id da regra é lido de
  `"id"` ou de `"d"`, as duas grafias que a documentação mostra.
  """
  @spec from_payload(map() | list()) :: [t()]
  def from_payload(payload) do
    payload
    |> Response.items(["split_rules", "splits"])
    |> Enum.flat_map(fn
      %{"recipient_account_id" => recipient} = rule when is_binary(recipient) ->
        [from_rule(rule, recipient)]

      _other ->
        []
    end)
  end

  @doc """
  Confere as regras antes da chamada.

  Sem o total (`nil`), aplica o que não depende dele: destinatário presente e
  sem repetição, pelo menos um valor por regra, valores positivos, `cents` e
  `percent` juntos só com `permit_aggregated`, percentuais que não alcançam
  100% e, com a opção `:own_account_id`, a conta criadora fora da lista. Com
  o total da fatura em centavos, confere também que o pior caso de
  `total_cents/3` fica abaixo dele, que é a regra cuja violação a Iugu não
  avisa.

  Devolve `{:error, %Iugu.Error{kind: :validation, status: nil}}`,
  como as outras checagens locais do SDK.
  """
  @spec validate([t()], non_neg_integer() | nil, keyword()) :: :ok | {:error, Error.t()}
  def validate(splits, invoice_total_cents \\ nil, opts \\ []) when is_list(splits) do
    with :ok <- validate_each(splits),
         :ok <- validate_recipients(splits, Keyword.get(opts, :own_account_id)),
         :ok <- validate_percent_share(splits) do
      validate_total(splits, invoice_total_cents)
    end
  end

  @doc """
  Quanto as regras tiram de uma fatura, em centavos.

  Com `payment_method:` (`"credit_card"`, `"bank_slip"` ou `"pix"`) e, no
  cartão, `installments:`, soma os campos genéricos com os daquela forma e
  daquele parcelamento. Sem essas opções estima o **pior caso**: a forma e o
  parcelamento que mais tiram da fatura, que é o número que interessa para
  garantir que o split nunca alcança o total.

  O percentual é calculado sobre o total e arredondado meio para cima; a
  Iugu não documenta o arredondamento dela.

      iex> splits = [Iugu.Split.percent("A", 10), Iugu.Split.fixed("B", 250)]
      iex> Iugu.Split.total_cents(splits, 10_000)
      1250

      iex> split = Iugu.Split.new(recipient_account_id: "A", cents: 100, pix_cents: 50, credit_card_percent: 3)
      iex> Iugu.Split.total_cents([split], 10_000, payment_method: "pix")
      150
      iex> Iugu.Split.total_cents([split], 10_000)
      400
  """
  @spec total_cents([t()], non_neg_integer(), keyword()) :: non_neg_integer()
  def total_cents(splits, invoice_total_cents, opts \\ [])
      when is_list(splits) and is_integer(invoice_total_cents) do
    Enum.reduce(splits, 0, fn split, total ->
      total + rule_cents(split, invoice_total_cents, opts)
    end)
  end

  @doc """
  Split padrão da conta que autentica.

  `GET /v1/splits/current`, sem assinatura, com o `api_token` da conta cujo
  split se quer ler em `api_token:` (a mestre lê o próprio com o token
  padrão). Devolve `id` do conjunto, `account_id` (o `splittable_id` da
  resposta), as regras como `t:t/0` e o corpo cru.
  """
  @spec current(keyword()) :: {:ok, default_split()} | {:error, Error.t()}
  def current(opts \\ []) do
    with {:ok, body} <- Client.get(@current_path, opts) do
      {:ok, normalize_default(body)}
    end
  end

  @doc """
  Substitui o split padrão da conta que autentica. Veja o moduledoc.

  `POST /v1/splits` com `split_rules`, sem assinatura, com o `api_token` da
  conta configurada em `api_token:`. As regras passam por `validate/3` (sem
  total, porque o split padrão vale para faturas de qualquer valor) antes de
  sair. A rota não aceita `Idempotency-Key`; como o efeito é substituir a
  configuração inteira, repetir a mesma lista é inofensivo, mas o SDK deixa
  o retry desligado por padrão como nas outras escritas.
  """
  @spec set_default([t()], keyword()) :: {:ok, default_split()} | {:error, Error.t()}
  def set_default(splits, opts \\ []) when is_list(splits) do
    {validation_opts, req_opts} = Keyword.split(opts, [:own_account_id])

    with :ok <- validate(splits, nil, validation_opts),
         {:ok, body} <- Client.post(@splits_path, %{"split_rules" => to_params(splits)}, req_opts) do
      {:ok, normalize_default(body)}
    end
  end

  defp normalize_default(body) do
    %{
      id: Map.get(body, "id"),
      account_id: Map.get(body, "splittable_id"),
      split_rules: from_payload(body),
      body: body
    }
  end

  defp to_param(%__MODULE__{} = split) do
    base =
      %{"recipient_account_id" => split.recipient_account_id}
      |> Params.put_present("permit_aggregated", split.permit_aggregated)

    generic_and_method =
      Enum.reduce([:cents, :percent | @method_fields], base, fn field, params ->
        Params.put_present(params, Atom.to_string(field), Map.fetch!(split, field))
      end)

    Enum.reduce(split.installments, generic_and_method, fn {installments, amounts}, params ->
      params
      |> Params.put_present("credit_card_#{installments}x_cents", amounts[:cents])
      |> Params.put_present("credit_card_#{installments}x_percent", amounts[:percent])
    end)
  end

  defp from_rule(rule, recipient) do
    split = %__MODULE__{
      id: Response.get_any(rule, ["id", "d"]),
      split_id: Map.get(rule, "split_id"),
      recipient_account_id: recipient,
      cents: read_cents(rule, "cents"),
      percent: read_percent(rule, "percent"),
      permit_aggregated: Map.get(rule, "permit_aggregated"),
      credit_card_cents: read_cents(rule, "credit_card_cents"),
      credit_card_percent: read_percent(rule, "credit_card_percent"),
      bank_slip_cents: read_cents(rule, "bank_slip_cents"),
      bank_slip_percent: read_percent(rule, "bank_slip_percent"),
      pix_cents: read_cents(rule, "pix_cents"),
      pix_percent: read_percent(rule, "pix_percent")
    }

    Enum.reduce(1..@max_installments, split, fn installments, split ->
      cents = read_cents(rule, "credit_card_#{installments}x_cents")
      percent = read_percent(rule, "credit_card_#{installments}x_percent")

      if is_nil(cents) and is_nil(percent) do
        split
      else
        put_in(split.installments[installments], %{cents: cents, percent: percent})
      end
    end)
  end

  defp read_cents(rule, key) do
    case Response.integer(rule, [key]) do
      nil -> nil
      0 -> nil
      cents -> cents
    end
  end

  defp read_percent(rule, key) do
    case Map.get(rule, key) do
      nil -> nil
      0 -> nil
      value when is_number(value) -> value
      value when is_binary(value) -> parse_percent(value)
      _other -> nil
    end
  end

  # "4" e "1.5" aparecem os dois na documentação; "4,99" é um erro de digitação
  # documentado e pararia na vírgula, então qualquer coisa com resto é ilegível.
  defp parse_percent(value) do
    case Float.parse(value) do
      {percent, ""} when percent == 0 -> nil
      {percent, ""} -> if percent == Float.floor(percent), do: trunc(percent), else: percent
      _other -> nil
    end
  end

  defp validate_each(splits) do
    Enum.reduce_while(splits, :ok, fn split, :ok ->
      case validate_rule(split) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_rule(%__MODULE__{recipient_account_id: recipient})
       when not is_binary(recipient) or recipient == "" do
    validation_error("Toda regra de split precisa de recipient_account_id.")
  end

  defp validate_rule(%__MODULE__{} = split) do
    amounts = amounts(split)

    cond do
      amounts == [] ->
        validation_error(
          "A regra para #{split.recipient_account_id} precisa de um valor em centavos ou em percentual."
        )

      Enum.any?(amounts, fn {_kind, value} -> not is_number(value) or value <= 0 end) ->
        validation_error(
          "A regra para #{split.recipient_account_id} tem valor que não é um número positivo."
        )

      aggregated?(amounts) and split.permit_aggregated != true ->
        validation_error(
          "A regra para #{split.recipient_account_id} junta centavos e percentual; isso exige permit_aggregated: true."
        )

      true ->
        :ok
    end
  end

  defp validate_recipients(splits, own_account_id) do
    recipients = Enum.map(splits, & &1.recipient_account_id)

    cond do
      own_account_id in recipients ->
        validation_error(
          "A conta criadora da fatura (#{own_account_id}) não pode ser destinatária do próprio split; ela recebe o que sobra."
        )

      Enum.uniq(recipients) != recipients ->
        validation_error("Cada conta destinatária pode aparecer uma vez só nos splits.")

      true ->
        :ok
    end
  end

  # O percentual sozinho tem que ficar abaixo de 100 seja qual for o valor da
  # fatura; a checagem baseada em centavos precisa do total e mora em
  # validate_total/2.
  defp validate_percent_share(splits) do
    share = Enum.reduce(splits, 0, fn split, share -> share + worst_case_percent(split) end)

    if share < 100 do
      :ok
    else
      validation_error(
        "Os percentuais dos splits somam #{share}%; a soma precisa ficar abaixo de 100% ou a Iugu ignora o split e a conta criadora recebe tudo."
      )
    end
  end

  defp validate_total(_splits, nil), do: :ok

  defp validate_total(splits, invoice_total_cents) when is_integer(invoice_total_cents) do
    taken = total_cents(splits, invoice_total_cents)

    if taken < invoice_total_cents do
      :ok
    else
      validation_error(
        "Os splits tiram #{taken} centavos de uma fatura de #{invoice_total_cents}; a soma precisa ficar abaixo do total ou a Iugu ignora o split e a conta criadora recebe tudo."
      )
    end
  end

  defp rule_cents(%__MODULE__{} = split, invoice_total_cents, opts) do
    generic = amount_cents(split.cents, split.percent, invoice_total_cents)

    case Keyword.get(opts, :payment_method) do
      nil ->
        generic + worst_case_method_cents(split, invoice_total_cents)

      method when method in @payment_methods ->
        generic +
          method_cents(split, method, invoice_total_cents, Keyword.get(opts, :installments))

      other ->
        raise ArgumentError,
              "forma de pagamento inválida: #{inspect(other)}. Use uma de #{inspect(@payment_methods)}."
    end
  end

  defp worst_case_method_cents(split, invoice_total_cents) do
    @payment_methods
    |> Enum.map(&method_cents(split, &1, invoice_total_cents, nil))
    |> Enum.max()
  end

  defp method_cents(split, method, invoice_total_cents, installments) do
    {cents_field, percent_field} = Map.fetch!(@method_amount_fields, method)

    per_method =
      amount_cents(
        Map.fetch!(split, cents_field),
        Map.fetch!(split, percent_field),
        invoice_total_cents
      )

    per_method + installment_cents(split, method, invoice_total_cents, installments)
  end

  defp installment_cents(_split, method, _invoice_total_cents, _installments)
       when method != "credit_card",
       do: 0

  defp installment_cents(split, "credit_card", invoice_total_cents, nil) do
    split.installments
    |> Map.values()
    |> Enum.map(&amount_cents(&1[:cents], &1[:percent], invoice_total_cents))
    |> Enum.max(fn -> 0 end)
  end

  defp installment_cents(split, "credit_card", invoice_total_cents, installments) do
    case Map.get(split.installments, installments) do
      nil -> 0
      amounts -> amount_cents(amounts[:cents], amounts[:percent], invoice_total_cents)
    end
  end

  defp amount_cents(cents, percent, invoice_total_cents) do
    (cents || 0) + percent_to_cents(percent, invoice_total_cents)
  end

  defp percent_to_cents(nil, _invoice_total_cents), do: 0

  defp percent_to_cents(percent, invoice_total_cents) do
    invoice_total_cents
    |> Decimal.new()
    |> Decimal.mult(to_decimal(percent))
    |> Decimal.div(100)
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end

  defp to_decimal(value) when is_integer(value), do: Decimal.new(value)
  defp to_decimal(value) when is_float(value), do: Decimal.from_float(value)

  defp worst_case_percent(%__MODULE__{} = split) do
    method_share =
      @payment_methods
      |> Enum.map(&method_percent(split, &1))
      |> Enum.max()

    (split.percent || 0) + method_share
  end

  defp method_percent(split, "credit_card") do
    installment_share =
      split.installments
      |> Map.values()
      |> Enum.map(&(&1[:percent] || 0))
      |> Enum.max(fn -> 0 end)

    (split.credit_card_percent || 0) + installment_share
  end

  defp method_percent(split, method) do
    {_cents_field, percent_field} = Map.fetch!(@method_amount_fields, method)

    Map.fetch!(split, percent_field) || 0
  end

  # Cada valor que a regra carrega, marcado por tipo, para que a regra de
  # agregação consiga distinguir "centavos ao lado de percentual" de "dois
  # campos de centavos".
  defp amounts(%__MODULE__{} = split) do
    generic_and_method =
      Enum.flat_map([:cents, :percent | @method_fields], fn field ->
        case Map.fetch!(split, field) do
          nil -> []
          value -> [{kind_of(field), value}]
        end
      end)

    per_installment =
      Enum.flat_map(split.installments, fn {_installments, amounts} ->
        Enum.reject([{:cents, amounts[:cents]}, {:percent, amounts[:percent]}], fn {_kind, value} ->
          is_nil(value)
        end)
      end)

    generic_and_method ++ per_installment
  end

  defp kind_of(field) do
    if field |> Atom.to_string() |> String.ends_with?("cents"), do: :cents, else: :percent
  end

  defp aggregated?(amounts) do
    kinds = amounts |> Enum.map(&elem(&1, 0)) |> Enum.uniq()

    :cents in kinds and :percent in kinds
  end

  defp put_installment(split, field, value) do
    {installments, kind} = installment_field(field)

    update_in(split.installments, fn installments_map ->
      Map.update(
        installments_map,
        installments,
        Map.put(%{cents: nil, percent: nil}, kind, value),
        &Map.put(&1, kind, value)
      )
    end)
  end

  defp installment_field(field) do
    "credit_card_" <> rest = Atom.to_string(field)

    case Integer.parse(rest) do
      {installments, "x_cents"} -> {installments, :cents}
      {installments, "x_percent"} -> {installments, :percent}
    end
  end

  defp fetch_recipient!(attrs) do
    case Map.get(attrs, :recipient_account_id) do
      recipient when is_binary(recipient) and recipient != "" ->
        recipient

      other ->
        raise ArgumentError,
              "recipient_account_id é obrigatório numa regra de split, recebido #{inspect(other)}"
    end
  end

  defp validation_error(message), do: {:error, Error.validation(message)}
end
