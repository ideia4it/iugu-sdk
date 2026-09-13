defmodule Iugu.Webhook.Event do
  @moduledoc """
  Normaliza o payload de gatilho que a Iugu posta na nossa URL.

  ## O corpo é um formulário, não JSON

  A Iugu envia `application/x-www-form-urlencoded` com chaves no estilo
  Rails: `event=invoice.status_changed&data[id]=...&data[status]=paid`. O
  `Plug.Parsers.URLENCODED` entrega isso como `%{"event" => _, "data" =>
  %{...}}`, que é o que `parse/1` recebe; `decode_form/1` faz o mesmo a
  partir do corpo cru, para logs e testes.

  Todo valor é string: centavos vêm `"1000"`, booleanos vêm `"true"`,
  `"false"` ou vazios (`data[async_charged]=` aparece assim nos logs), datas
  vêm ISO 8601 em UTC (`2022-03-21T11:07:36.667Z`) ou `AAAA-MM-DD`. Os
  leitores tipados (`integer_field/2`, `boolean_field/2`,
  `datetime_field/2`) convertem e devolvem `nil` para o que não dá para ler,
  nunca zero nem `false` por engano.

  ## As tabelas não concordam entre si

  A maioria dos eventos documenta `event` no topo e os campos em `data[...]`.
  Os de Pix/TED para terceiros, depósito por Pix e ordem de pagamento
  documentam as chaves **sem** o prefixo `data[]`, e os de transferência
  entre contas, parcela de split e depósito por TED documentam o nome do
  evento em `data[event]`. Se isso é diferença real no que chega ou descuido
  da documentação **não está confirmado**, então `parse/1` lê o nome de
  `event` ou de `data[event]`, e `data` reúne as chaves de dentro de `data`
  com as que vieram soltas no topo.

  ## Conferência da origem

  Não há assinatura na entrega. O que existe é o `authorization` cadastrado
  no gatilho, que a Iugu devolve no header `Authorization` de cada chamada.
  `authorized?/2` compara em tempo constante com o valor configurado
  (`Iugu.Config.webhook_authorization/0`), aceitando o valor cru e
  a forma `Basic base64(valor)`, porque a documentação não diz qual das duas
  a Iugu usa. Sem segredo configurado a resposta é sempre `false`. Combine
  com a allowlist do IP de saída (`Iugu.Webhook.outbound_ip/0`) e,
  para dinheiro, releia o objeto na API antes de agir.

  ## Idempotência

  A retentativa automática não está documentada, mas `force_retry/2` e
  `resend_by_period/3` em `Iugu.Webhook` repetem o payload original
  tal qual, e a Iugu aceita gatilhos duplicados para o mesmo evento. O
  receptor responde 2xx na hora e deduplica por `idempotency_key/1` (evento,
  id do objeto e status) antes de processar.

  ## Lista fechada de eventos

  `parse/1` casa o nome contra `Iugu.Webhook.events/0` e devolve
  `{:error, :unsupported_event}` fora dela, em vez de `String.to_atom/1` em
  valor vindo da rede. Um gatilho `all` recebe evento novo que a Iugu criar
  depois; ele cai aqui até o catálogo ser atualizado.
  """

  alias Iugu.Config
  alias Iugu.Response
  alias Iugu.Webhook
  alias Plug.Conn.Query

  @type t :: %__MODULE__{
          event: String.t(),
          account_id: String.t() | nil,
          data: %{optional(String.t()) => term()},
          payload: map()
        }

  @enforce_keys [:event, :data, :payload]
  defstruct [:event, :account_id, :payload, data: %{}]

  @doc """
  Lê o payload já decodificado pelo Plug.

  Devolve `{:error, :unsupported_event}` quando não há nome de evento, quando
  ele não é string ou quando está fora do catálogo.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, :unsupported_event}
  def parse(%{} = payload) do
    nested = nested_data(payload)
    event = Map.get(payload, "event") || Map.get(nested, "event")

    if is_binary(event) and event in deliverable_events() do
      data =
        payload
        |> Map.drop(["event", "data"])
        |> Map.merge(nested)
        |> Map.delete("event")

      {:ok,
       %__MODULE__{
         event: event,
         account_id: string_or_nil(Map.get(data, "account_id")),
         data: data,
         payload: payload
       }}
    else
      {:error, :unsupported_event}
    end
  end

  def parse(_payload), do: {:error, :unsupported_event}

  @doc """
  Lê o corpo cru `application/x-www-form-urlencoded`.

      iex> Iugu.Webhook.Event.decode_form("event=invoice.created&data%5Bid%5D=ABC&data%5Bstatus%5D=pending")
      ...> |> then(fn {:ok, event} -> {event.event, event.data} end)
      {"invoice.created", %{"id" => "ABC", "status" => "pending"}}
  """
  @spec decode_form(binary()) :: {:ok, t()} | {:error, :unsupported_event}
  def decode_form(raw_body) when is_binary(raw_body) do
    raw_body
    |> Query.decode()
    |> parse()
  end

  @doc """
  Se o header `Authorization` recebido é o segredo cadastrado no gatilho.

  `received` é o valor do header (ou a lista que
  `Plug.Conn.get_req_header/2` devolve); `expected` é o que cadastramos, por
  padrão `Iugu.Config.webhook_authorization/0`. Comparação em tempo
  constante via `Plug.Crypto.secure_compare/2`, aceitando o valor cru ou
  `Basic base64(valor)`. Sem header, sem segredo ou segredo vazio: `false`.

      iex> Iugu.Webhook.Event.authorized?("s3cr3t", "s3cr3t")
      true

      iex> Iugu.Webhook.Event.authorized?(["Basic " <> Base.encode64("s3cr3t")], "s3cr3t")
      true

      iex> Iugu.Webhook.Event.authorized?("outro", "s3cr3t")
      false

      iex> Iugu.Webhook.Event.authorized?("s3cr3t", nil)
      false
  """
  @spec authorized?(String.t() | [String.t()] | nil, String.t() | nil) :: boolean()
  def authorized?(received, expected \\ Config.webhook_authorization())

  def authorized?([received], expected), do: authorized?(received, expected)

  def authorized?(received, expected)
      when is_binary(received) and is_binary(expected) and expected != "" do
    Plug.Crypto.secure_compare(received, expected) or
      Plug.Crypto.secure_compare(received, "Basic " <> Base.encode64(expected))
  end

  def authorized?(_received, _expected), do: false

  @doc """
  Chave para deduplicar entregas repetidas: evento, id do objeto e status.

  Reenvio manual e por período repetem o payload original, e gatilhos
  duplicados entregam o mesmo evento duas vezes. Sem id legível (antecipação
  de recebíveis, documento de KYC) entra um hash do `data` inteiro.
  """
  @spec idempotency_key(t()) :: String.t()
  def idempotency_key(%__MODULE__{} = event) do
    id = object_id(event) || "hash-#{:erlang.phash2(event.data)}"

    Enum.join([event.event, id, status(event) || "-"], "|")
  end

  @doc """
  Id do objeto do evento, conforme a família.

  Fatura, assinatura e verificação usam `id`; saque, `withdraw_request_id`;
  Pix/TED para terceiros, `transfer_request_id`; transferência entre contas,
  `transfer_id`; depósito, `deposit_id`; ordem de pagamento,
  `payment_request_id`; forma de pagamento, `customer_payment_method_id`.
  """
  @spec object_id(t()) :: String.t() | nil
  def object_id(%__MODULE__{event: event} = struct) do
    field(struct, id_key(event))
  end

  @doc "Status do objeto (`status`, ou `transfer_status` nos Pix/TED para terceiros)."
  @spec status(t()) :: String.t() | nil
  def status(%__MODULE__{data: data}) do
    string_or_nil(Response.get_any(data, ["status", "transfer_status"]))
  end

  @doc "Campo cru de `data`, string ou `nil`."
  @spec field(t(), String.t()) :: String.t() | nil
  def field(%__MODULE__{data: data}, key) when is_binary(key) do
    string_or_nil(Map.get(data, key))
  end

  @doc """
  Campo inteiro (centavos, parcelas). `nil` para ausente, vazio ou não
  inteiro; `"161.0"` vira 161 como no extrato.
  """
  @spec integer_field(t(), String.t()) :: integer() | nil
  def integer_field(%__MODULE__{data: data}, key) when is_binary(key) do
    Response.integer(data, [key])
  end

  @doc """
  Campo booleano: `"true"` e `"false"` como manda a documentação; vazio ou
  ausente é `nil`, não `false`, porque `data[async_charged]=` chega vazio
  nos logs sem significar negação.
  """
  @spec boolean_field(t(), String.t()) :: boolean() | nil
  def boolean_field(%__MODULE__{data: data}, key) when is_binary(key) do
    case Map.get(data, key) do
      "true" -> true
      "false" -> false
      true -> true
      false -> false
      _other -> nil
    end
  end

  @doc "Campo de data e hora ISO 8601 (`2022-03-21T11:07:36.667Z`) como `DateTime`, ou `nil`."
  @spec datetime_field(t(), String.t()) :: DateTime.t() | nil
  def datetime_field(%__MODULE__{} = event, key) do
    with value when is_binary(value) <- field(event, key),
         {:ok, datetime, _offset} <- DateTime.from_iso8601(value) do
      datetime
    else
      _other -> nil
    end
  end

  @doc "Campo de data `AAAA-MM-DD` como `Date`, ou `nil`."
  @spec date_field(t(), String.t()) :: Date.t() | nil
  def date_field(%__MODULE__{} = event, key) do
    with value when is_binary(value) <- field(event, key),
         {:ok, date} <- Date.from_iso8601(value) do
      date
    else
      _other -> nil
    end
  end

  @doc "Se é um evento de fatura (`invoice.*`)."
  @spec invoice_event?(t()) :: boolean()
  def invoice_event?(%__MODULE__{event: event}), do: event in Webhook.invoice_events()

  @doc "Se é um evento de assinatura (`subscription.*`)."
  @spec subscription_event?(t()) :: boolean()
  def subscription_event?(%__MODULE__{event: event}),
    do: event in Webhook.subscription_events()

  @doc "Se é um evento de verificação de subconta (`referrals.*`)."
  @spec kyc_event?(t()) :: boolean()
  def kyc_event?(%__MODULE__{event: event}), do: event in Webhook.kyc_events()

  @doc "Se é um evento de saque (`withdraw_request.*`)."
  @spec withdraw_event?(t()) :: boolean()
  def withdraw_event?(%__MODULE__{event: event}), do: event in Webhook.withdraw_events()

  @doc "Se é um evento de transferência (`transfer_request.*` ou `transfer.*`)."
  @spec transfer_event?(t()) :: boolean()
  def transfer_event?(%__MODULE__{event: event}), do: event in Webhook.transfer_events()

  @doc """
  Id da fatura, só nos eventos `invoice.*`.

  Num evento de assinatura `data[id]` é a assinatura, então aqui volta `nil`
  em vez de um id que não é de fatura.
  """
  @spec invoice_id(t()) :: String.t() | nil
  def invoice_id(%__MODULE__{} = event) do
    if invoice_event?(event), do: field(event, "id"), else: nil
  end

  @doc """
  Id da assinatura: `data[subscription_id]` numa fatura ("Enviado apenas para
  faturas criadas por Assinaturas") ou `data[id]` num evento `subscription.*`.
  """
  @spec subscription_id(t()) :: String.t() | nil
  def subscription_id(%__MODULE__{} = event) do
    cond do
      subscription_event?(event) -> field(event, "id")
      invoice_event?(event) -> field(event, "subscription_id")
      true -> nil
    end
  end

  @doc """
  Se a fatura está paga: evento `invoice.*` com `status` `paid`.

  Para cartão e Pix é o sinal de dinheiro recebido; para boleto `paid` dispara
  na compensação. `invoice.released` (só em produção) é o lado da liquidação.
  `partially_paid`, `authorized` e `externally_paid` não contam.
  """
  @spec paid?(t()) :: boolean()
  def paid?(%__MODULE__{} = event), do: invoice_event?(event) and status(event) == "paid"

  @doc "Meio de pagamento da fatura: `iugu_bank_slip`, `iugu_credit_card` ou `iugu_pix`."
  @spec payment_method(t()) :: String.t() | nil
  def payment_method(%__MODULE__{} = event), do: field(event, "payment_method")

  @doc "Valor pago em centavos (`data[paid_cents]`)."
  @spec paid_cents(t()) :: integer() | nil
  def paid_cents(%__MODULE__{} = event), do: integer_field(event, "paid_cents")

  @doc "Momento do pagamento (`data[paid_at]`) como `DateTime`."
  @spec paid_at(t()) :: DateTime.t() | nil
  def paid_at(%__MODULE__{} = event), do: datetime_field(event, "paid_at")

  @doc "`order_id` informado na criação da fatura, o id que nós controlamos."
  @spec order_id(t()) :: String.t() | nil
  def order_id(%__MODULE__{} = event), do: field(event, "order_id")

  @doc "`external_reference` informado na criação da fatura."
  @spec external_reference(t()) :: String.t() | nil
  def external_reference(%__MODULE__{} = event), do: field(event, "external_reference")

  @doc "CPF ou CNPJ do pagador, só dígitos (`data[payer_cpf_cnpj]`)."
  @spec payer_cpf_cnpj(t()) :: String.t() | nil
  def payer_cpf_cnpj(%__MODULE__{} = event), do: field(event, "payer_cpf_cnpj")

  @doc "End to end id do Pix que pagou a fatura."
  @spec pix_end_to_end_id(t()) :: String.t() | nil
  def pix_end_to_end_id(%__MODULE__{} = event), do: field(event, "pix_end_to_end_id")

  @doc """
  Se a subconta foi verificada: `referrals.verification` com `status`
  `accepted` ("Conta aceita e Verificada. Apta a transacionar.").

  `rejected` é "Conta recusada e Não verificada", com o motivo em
  `feedback/1`. A Iugu responde em até 2 dias úteis, e contas com dados
  divergentes são desverificadas periodicamente, então o mesmo evento pode
  chegar de novo com `rejected` meses depois.
  """
  @spec verified?(t()) :: boolean()
  def verified?(%__MODULE__{event: "referrals.verification"} = event),
    do: status(event) == "accepted"

  def verified?(%__MODULE__{}), do: false

  @doc """
  Motivo de recusa nos eventos de KYC: `feedback` na verificação de conta e de
  domicílio bancário, `reason` na recusa de documento.
  """
  @spec feedback(t()) :: String.t() | nil
  def feedback(%__MODULE__{data: data}) do
    string_or_nil(Response.get_any(data, ["feedback", "reason"]))
  end

  @doc "Limite de cobrança da subconta verificada, em centavos (`data[charge_limit_cents]`)."
  @spec charge_limit_cents(t()) :: integer() | nil
  def charge_limit_cents(%__MODULE__{} = event), do: integer_field(event, "charge_limit_cents")

  @doc """
  Tipo do documento em `referrals.document_status_change`: `identification`,
  `selfie`, `balance_sheet`, `social_contract`, `additional_document_one` ou
  `additional_document_two`.

  A documentação escreve `additiconal_document_*`; se o valor na entrega
  carrega o erro de grafia **não está confirmado**, e as duas formas voltam
  corrigidas.
  """
  @spec document_type(t()) :: String.t() | nil
  def document_type(%__MODULE__{} = event) do
    case field(event, "document_type") do
      nil -> nil
      type -> String.replace(type, "additiconal_", "additional_")
    end
  end

  @doc "Valor em centavos (`data[amount_cents]`) nos eventos de saque, transferência, depósito e split."
  @spec amount_cents(t()) :: integer() | nil
  def amount_cents(%__MODULE__{} = event), do: integer_field(event, "amount_cents")

  defp nested_data(payload) do
    case Map.get(payload, "data") do
      %{} = data -> data
      _other -> %{}
    end
  end

  defp deliverable_events, do: Webhook.events() -- ["all"]

  defp id_key("withdraw_request." <> _rest), do: "withdraw_request_id"
  defp id_key("transfer_request." <> _rest), do: "transfer_request_id"
  defp id_key("transfer." <> _rest), do: "transfer_id"
  defp id_key("deposit." <> _rest), do: "deposit_id"
  defp id_key("payment_request." <> _rest), do: "payment_request_id"
  defp id_key("customer_payment_method." <> _rest), do: "customer_payment_method_id"
  defp id_key(_event), do: "id"

  defp string_or_nil(value) when is_binary(value) and value != "", do: value
  defp string_or_nil(_value), do: nil
end
