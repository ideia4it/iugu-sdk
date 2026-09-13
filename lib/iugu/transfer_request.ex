defmodule Iugu.TransferRequest do
  @moduledoc """
  Transferência para terceiros: Pix ou TED da conta Iugu para uma conta
  bancária que não precisa ser do mesmo titular.

  A Iugu chama o recurso de `transfer_request` e o id de
  `transfer_request_id`; é o nome que aparece nos webhooks
  (`transfer_request.status_changed`, `transfer_request.done`,
  `transfer_request.rejected`, `transfer_request.pix_status_changed`) e que
  este módulo mantém. O saque para o domicílio bancário do próprio titular é
  outra rota, `Iugu.Account.request_withdraw/3`, e mandar dinheiro
  para outra conta Iugu é `Iugu.Transfer`: esta rota recusa uma
  conta Iugu como destino ("Can't create a transfer request to iugu. Use the
  'Transfer between iugu accounts' feature for this.").

  ## Token, assinatura e idempotência

  `create/2` autentica com o `live_api_token` da conta que paga (subconta ou
  mestre) e exige a assinatura RSA ("a assinatura da requisição utilizando a
  tecnologia RSA é obrigatória"). Como a assinatura só funciona em produção,
  na prática a rota é só de produção; se o sandbox aceita a chamada sem
  assinatura **não está documentado**. No fluxo whitelabel a chave privada é
  a da mestre e o token, o da subconta (veja `Iugu.Client`).

  A rota aceita `Idempotency-Key`: com `:idempotency_key`, `create/2` liga o
  retry (`:transient`) e uma repetição responde 409, devolvido como
  `kind: :validation, status: 409`. Sem a chave a chamada **nunca repete**,
  porque um timeout pode ter enviado o Pix.

  Desde 2026-08-20 a Iugu exige "um intervalo mínimo de 5 segundos entre uma
  solicitação de transferência para terceiros e a próxima" na mesma conta; a
  segunda responde `Já existe uma transferência em processamento nesta
  conta. Espere a conclusão e tente novamente.` (status HTTP **não
  documentado**). Quem despacha em lote espaça as chamadas por conta.

  ## Valor, tarifa e saldo

  `amount_cents` é inteiro em centavos, mínimo 2 ("Valor mínimo 2
  centavos"). A tarifa sai da mesma conta: "não esqueça de validar se sua
  Conta iugu possui saldo suficiente para cumprir o valor requisitado na
  transferência, somado ao valor da sua taxa." Saldo insuficiente é 422
  `amount_cents: maior que o saldo da conta`, e há um limite por perfil
  (`transfers quantity limit per profile exceeded`) que só o suporte
  altera.

  ## Chave Pix ou dados bancários

  "O hash de PIX só funciona quando o transfer_type for definido como PIX,
  mas o array de BANK funciona tanto para transfer_type definido como PIX ou
  como TED. Isso porque é possível fazer PIX para uma conta corrente."
  Então `receiver` tem três formas, e `create/2` confere antes da chamada:

    * Pix por chave: `transfer_type: "pix"` e `receiver.pix` com `type`
      (`cpf`, `cnpj`, `email`, `phone`, `evp`) e `key`. Chave sem conta
      vinculada é 404
    * Pix ou TED para conta: `receiver.name` (até 140 caracteres),
      `receiver.cpf_cnpj` e `receiver.bank` com `ispb` (8 dígitos) ou
      `compe` (3 dígitos), `branch` (dispensada só em `payment_account`),
      `account` e `account_type` (`checking_account`, `salary_account`,
      `savings_account`, `payment_account`)
    * `institucional`: `receiver.name`, `cpf_cnpj`, `bank` com `ispb` e
      `branch`, mais `hist` e `cit` no corpo

  Chave e dados bancários juntos são aceitos, e a Iugu confere se apontam
  para a mesma conta (400 quando não). `check_payer` recebe o CPF/CNPJ que a
  chave Pix precisa ter; divergência é 422 `Documento do recebedor não
  condiz com o informado`.

  ## O 200 não é o desfecho

  "A requisição retornará 200 se todos os campos informados estiverem
  corretos. No entanto, isso não significa que a transferência será
  processada com sucesso": o banco de destino pode recusar. O ciclo é
  `pending` → `processing` → `done` ou `rejected`; um Pix pode ainda virar
  `refunded` ou `partially_refunded`, e um Pix com `scheduled_date` nasce
  `scheduled` até `cancel_scheduled/2` ou a execução. `done` é final para
  Pix, mas **para TED pode virar `rejected` em até 24 horas** ("Done pode
  ser considerado status final se passar 24hs nesse status"); `final?/2`
  aplica essa regra. Crie o webhook `transfer_request.status_changed` antes
  de transferir e guarde o `transfer_request_id`: "A notificação só será
  disparada após o processamento da transferência."

  Toda transferência expõe `receipt_url`, o comprovante em PDF em
  `comprovantes.iugu.com`; não há rota separada de comprovante, `get/2` e
  `list/1` são elas.

  ## O que não está confirmado

    * o status HTTP do erro de intervalo de 5 segundos, e o envelope JSON
      dos 400 (a documentação mostra `{}`)
    * se `receiver.bank.compe` ainda é aceito (só o guia o cita; o esquema
      lista apenas `ispb`) e os valores de `qrcode_type`
    * se `end_to_end_id` vem `null` ou ausente numa TED; se `query` em
      `list/1` é de fato opcional (o OpenAPI o marca como obrigatório num
      caminho sem placeholder)
    * qual das duas formas de `GET /v1/transfer_requests/{id}` a produção
      devolve hoje (`get/2` lê as duas); se `receipt_url` exige autenticação
    * se `status` `error` dos webhooks é terminal
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Pagination
  alias Iugu.Params
  alias Iugu.Response

  @path "/v1/transfer_requests"
  # A referência documenta a listagem com barra no final, diferente do POST;
  # o Rails aceita as duas, e o SDK segue a página.
  @list_path "/v1/transfer_requests/"
  @decode_qrcode_path "/v1/transfer_requests/decode_qrcode"
  @max_limit 100
  @minimum_amount_cents 2
  @max_receiver_name_length 140
  @max_conciliation_id_length 35
  @ted_done_settles_after_hours 24

  @transfer_types ["ted", "pix", "institucional"]
  @pix_key_types ["cpf", "cnpj", "email", "phone", "evp"]
  @account_types ["checking_account", "salary_account", "savings_account", "payment_account"]
  @statuses [
    "pending",
    "processing",
    "done",
    "rejected",
    "refunded",
    "partially_refunded",
    "scheduled",
    "cancelled",
    "error"
  ]
  @final_statuses ["rejected", "refunded", "cancelled"]
  @sort_fields ["amount_cents", "executed_at"]
  @create_fields [
    :transfer_type,
    :amount_cents,
    :description,
    :external_reference,
    :conciliation_id,
    :scheduled_date,
    :check_payer,
    :end_to_end_id,
    :qrcode_type,
    :receiver,
    :hist,
    :cit,
    :reason_code
  ]
  @date_filters [:updated_at_from, :updated_at_to]
  @list_filters [:start, :limit, :sort_by, :query] ++ @date_filters

  @type t :: %{
          id: String.t() | nil,
          status: String.t() | nil,
          transfer_type: String.t() | nil,
          amount_cents: integer() | nil,
          description: String.t() | nil,
          external_reference: String.t() | nil,
          end_to_end_id: String.t() | nil,
          receipt_url: String.t() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          executed_at: String.t() | nil,
          rejected_at: String.t() | nil,
          rejected_reason: String.t() | nil,
          sender_account: map() | nil,
          receiver_account: map() | nil,
          body: map()
        }

  @type page :: %{transfer_requests: [t()], page_info: Pagination.page_info()}

  @doc """
  Envia um Pix ou uma TED para terceiros. Veja o moduledoc.

  Requisição assinada, autenticada com o `live_api_token` da conta pagadora
  em `api_token:`. `attrs` vai no formato da API (chaves em átomo ou string,
  `receiver` aninhado), com `scheduled_date` aceitando `Date`. O que a Iugu
  recusaria com 400 volta como `{:error, %Iugu.Error{kind:
  :validation, status: nil}}` sem ir lá; uma chave fora da lista documentada
  levanta `ArgumentError`. Opção `:idempotency_key` (header e retry; sem
  ela a chamada nunca repete).

  A resposta (202 na referência, 200 no guia) vem normalizada como em
  `get/2`, com o id lido de `transfer_request_id`.
  """
  @spec create(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    {create_opts, req_opts} = Keyword.split(opts, [:idempotency_key])
    body = build_create_body(attrs)

    with :ok <- validate_create(body) do
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
  Consulta uma transferência para terceiros pelo `transfer_request_id`, com
  o comprovante em `receipt_url`.

  Autenticada com o token da conta pagadora. Sem assinatura. A documentação
  publica duas formas de resposta para a mesma rota; o mapa normalizado lê as
  duas (`rejected_reason` também de `reson`, `updated_at` também de
  `updated`) e mantém `sender_account` e `receiver_account` como vieram, com
  os documentos mascarados. Id desconhecido é 404 (`Transferência não
  encontrada`).
  """
  @spec get(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def get(transfer_request_id, opts \\ []) when is_binary(transfer_request_id) do
    with {:ok, body} <- Client.get(item_path(transfer_request_id), opts) do
      {:ok, normalize(body)}
    end
  end

  @doc """
  Comprovantes de transferência para terceiros da conta, paginados.

  `GET /v1/transfer_requests/`, token da conta. Filtros: `:start`, `:limit`
  (preso a 100), `:query` (busca livre "como valor, chave PIX ou banco"),
  `:sort_by` (`"amount_cents"` ou `"executed_at"`, a única ordenação
  documentada na API), `:updated_at_from` e `:updated_at_to` (`Date`,
  `DateTime` no horário de São Paulo ou string).
  """
  @spec list(keyword()) :: {:ok, page()} | {:error, Error.t()}
  def list(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, @list_filters)

    with :ok <-
           Params.validate_member(
             Keyword.get(filter_opts, :sort_by),
             @sort_fields,
             "sort_by",
             @path
           ),
         params = list_params(filter_opts),
         {:ok, body} <- Client.get(@list_path, Keyword.put(req_opts, :params, params)) do
      {:ok,
       %{
         transfer_requests: body |> Response.items() |> Enum.map(&normalize/1),
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
          {:ok, page.transfer_requests}
        end
      end,
      ["items"],
      Keyword.put(page_opts, :max_limit, @max_limit)
    )
  end

  @doc """
  Cancela um Pix agendado (`scheduled_date` em `create/2`).

  `PATCH /v1/transfer_requests/{id}/scheduled_cancel`, `live_api_token` da
  conta pagadora, sem corpo e sem assinatura declarada. Só funciona com
  status `scheduled`; fora dele a Iugu responde 400 `Transfer status must be
  scheduled.`. Sem retry: a pré-condição de status já transforma a
  repetição num 400. A resposta vem normalizada, com `status: "cancelled"`.
  """
  @spec cancel_scheduled(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def cancel_scheduled(transfer_request_id, opts \\ []) when is_binary(transfer_request_id) do
    path = "#{item_path(transfer_request_id)}/scheduled_cancel"

    with {:ok, body} <- Client.request(:patch, path, opts) do
      {:ok, normalize(body)}
    end
  end

  @doc """
  Lê o que está dentro de um QR Code Pix antes de pagá-lo com `create/2`.

  `POST /v1/transfer_requests/decode_qrcode`, token da conta, sem assinatura.
  "Ele não processa a imagem do QR Code diretamente, mas atua sobre a string
  gerada a partir da imagem": `payload` é o copia-e-cola. A resposta traz
  `type` (`dynamic_qr_code` ou estático), `end_to_end_id` e, em `qr_code`,
  recebedor, valor (`amount`, em reais), `conciliation_id`, validade
  (`qr_expires_in`) e `status`, como a Iugu escreve. Como só lê, repete em
  falha transitória.
  """
  @spec decode_qrcode(String.t(), keyword()) ::
          {:ok,
           %{type: String.t() | nil, end_to_end_id: String.t() | nil, qr_code: map(), body: map()}}
          | {:error, Error.t()}
  def decode_qrcode(payload, opts \\ []) when is_binary(payload) do
    with :ok <- validate_present(%{"qrcode_payload" => payload}, "qrcode_payload", "payload"),
         {:ok, body} <-
           Client.post(
             @decode_qrcode_path,
             %{"qrcode_payload" => payload},
             Keyword.put_new(opts, :retry, :transient)
           ) do
      {:ok,
       %{
         type: Map.get(body, "type"),
         end_to_end_id: Map.get(body, "end_to_end_id"),
         qr_code: Map.get(body, "qr_code") || %{},
         body: body
       }}
    end
  end

  @doc """
  Se o status da transferência não muda mais.

  `rejected`, `refunded` e `cancelled` são finais. `done` é final para Pix;
  para TED só depois de 24 horas em `done`, contadas de `executed_at` (ou
  `updated_at`) até `now`, porque o banco de destino ainda pode devolver.
  Sem data legível, uma TED `done` fica como não final. `partially_refunded`
  e `error` não entram, porque a documentação não diz que são terminais.
  """
  @spec final?(t() | map(), DateTime.t()) :: boolean()
  def final?(transfer_request, now \\ DateTime.utc_now())

  def final?(%{status: status} = transfer_request, now) do
    final_status?(
      status,
      Map.get(transfer_request, :transfer_type),
      Map.get(transfer_request, :executed_at) || Map.get(transfer_request, :updated_at),
      now
    )
  end

  def final?(transfer_request, now) when is_map(transfer_request) do
    transfer_request |> normalize() |> final?(now)
  end

  @doc "Tipos de transferência aceitos em `transfer_type`."
  @spec transfer_types() :: [String.t()]
  def transfer_types, do: @transfer_types

  @doc "Tipos de chave Pix aceitos em `receiver.pix.type`."
  @spec pix_key_types() :: [String.t()]
  def pix_key_types, do: @pix_key_types

  @doc "Tipos de conta aceitos em `receiver.bank.account_type`."
  @spec account_types() :: [String.t()]
  def account_types, do: @account_types

  @doc "Os status documentados, reunindo referência, guia e webhooks."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  defp normalize(body) when is_map(body) do
    %{
      id: Response.get_any(body, ["transfer_request_id", "id"]),
      status: Map.get(body, "status"),
      transfer_type: Map.get(body, "transfer_type"),
      amount_cents: Response.integer(body, ["amount_cents"]),
      description: Map.get(body, "description"),
      external_reference: Map.get(body, "external_reference"),
      end_to_end_id: Map.get(body, "end_to_end_id"),
      receipt_url: Map.get(body, "receipt_url"),
      created_at: Map.get(body, "created_at"),
      updated_at: Response.get_any(body, ["updated_at", "updated"]),
      executed_at: Map.get(body, "executed_at"),
      rejected_at: Map.get(body, "rejected_at"),
      rejected_reason: Response.get_any(body, ["rejected_reason", "reson", "reason"]),
      sender_account: Map.get(body, "sender_account"),
      receiver_account: Map.get(body, "receiver_account"),
      body: body
    }
  end

  defp final_status?(status, _type, _executed_at, _now) when status in @final_statuses, do: true
  defp final_status?("done", "pix", _executed_at, _now), do: true

  defp final_status?("done", "ted", executed_at, now) when is_binary(executed_at) do
    case DateTime.from_iso8601(executed_at) do
      {:ok, executed_at, _offset} ->
        DateTime.diff(now, executed_at, :hour) >= @ted_done_settles_after_hours

      {:error, _reason} ->
        false
    end
  end

  defp final_status?(_status, _type, _executed_at, _now), do: false

  defp build_create_body(attrs) do
    Map.new(attrs, fn {key, value} ->
      field = Params.field!(key, @create_fields, "transferência para terceiros")

      {Atom.to_string(field), convert_value(field, value)}
    end)
  end

  defp convert_value(:scheduled_date, %Date{} = date), do: Date.to_iso8601(date)
  defp convert_value(:receiver, %{} = receiver), do: deep_stringify_keys(receiver)
  defp convert_value(_field, value), do: value

  defp deep_stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), deep_stringify_keys(value)} end)
  end

  defp deep_stringify_keys(value), do: value

  defp validate_create(body) do
    transfer_type = Map.get(body, "transfer_type")
    receiver = Map.get(body, "receiver")

    with :ok <- Params.validate_member(transfer_type, @transfer_types, "transfer_type", @path),
         :ok <- validate_amount(Map.get(body, "amount_cents")),
         :ok <- validate_receiver_present(receiver),
         :ok <- validate_receiver(transfer_type, receiver),
         :ok <- validate_institutional(transfer_type, body) do
      validate_conciliation_id(Map.get(body, "conciliation_id"))
    end
  end

  defp validate_amount(amount_cents)
       when is_integer(amount_cents) and amount_cents >= @minimum_amount_cents,
       do: :ok

  defp validate_amount(_amount_cents) do
    validation_error("amount_cents é obrigatório, inteiro em centavos e no mínimo 2.")
  end

  defp validate_receiver_present(%{} = receiver) when map_size(receiver) > 0, do: :ok
  defp validate_receiver_present(_receiver), do: validation_error("receiver é obrigatório.")

  # A chave Pix sozinha basta para um Pix; qualquer outro caso (TED, Pix para
  # uma conta, institucional) precisa do titular e dos dados bancários.
  defp validate_receiver("pix", %{"pix" => pix} = receiver) do
    with :ok <- validate_pix_key(pix) do
      if Map.has_key?(receiver, "bank"),
        do: validate_bank_receiver(receiver, "pix"),
        else: :ok
    end
  end

  defp validate_receiver(transfer_type, %{"pix" => _pix}) when transfer_type != "pix" do
    validation_error(
      "receiver.pix só vale com transfer_type pix; para #{transfer_type} envie receiver.bank."
    )
  end

  defp validate_receiver(transfer_type, receiver),
    do: validate_bank_receiver(receiver, transfer_type)

  defp validate_pix_key(%{} = pix) do
    with :ok <- validate_present(pix, "type", "receiver.pix.type"),
         :ok <-
           Params.validate_member(
             Map.get(pix, "type"),
             @pix_key_types,
             "receiver.pix.type",
             @path
           ) do
      validate_present(pix, "key", "receiver.pix.key")
    end
  end

  defp validate_pix_key(_pix),
    do: validation_error("receiver.pix deve ser um mapa com type e key.")

  defp validate_bank_receiver(receiver, transfer_type) do
    bank = Map.get(receiver, "bank")

    with :ok <- validate_present(receiver, "name", "receiver.name"),
         :ok <- validate_name_length(Map.get(receiver, "name")),
         :ok <- validate_present(receiver, "cpf_cnpj", "receiver.cpf_cnpj"),
         :ok <- validate_bank_present(bank),
         :ok <- validate_bank_code(bank),
         :ok <- validate_branch(bank) do
      validate_account(bank, transfer_type)
    end
  end

  defp validate_name_length(name) when is_binary(name) do
    if String.length(name) <= @max_receiver_name_length do
      :ok
    else
      validation_error("receiver.name deve ter no máximo 140 caracteres.")
    end
  end

  defp validate_name_length(_name), do: :ok

  defp validate_bank_present(%{} = bank) when map_size(bank) > 0, do: :ok

  defp validate_bank_present(_bank) do
    validation_error("receiver.bank é obrigatório quando não há chave Pix.")
  end

  defp validate_bank_code(bank) do
    cond do
      Params.present?(bank, "ispb") -> validate_ispb(Map.get(bank, "ispb"))
      Params.present?(bank, "compe") -> validate_compe(Map.get(bank, "compe"))
      true -> validation_error("receiver.bank precisa de ispb (8 dígitos) ou compe (3 dígitos).")
    end
  end

  defp validate_ispb(ispb) do
    if is_binary(ispb) and Regex.match?(~r/\A\d{8}\z/, ispb),
      do: :ok,
      else: validation_error("receiver.bank.ispb deve ter 8 dígitos como string.")
  end

  defp validate_compe(compe) do
    if is_binary(compe) and Regex.match?(~r/\A\d{3}\z/, compe),
      do: :ok,
      else: validation_error("receiver.bank.compe deve ter 3 dígitos como string.")
  end

  defp validate_branch(%{"account_type" => "payment_account"}), do: :ok
  defp validate_branch(bank), do: validate_present(bank, "branch", "receiver.bank.branch")

  # Transferências institucionais documentam só ispb e branch; TED e Pix para
  # uma conta precisam do número da conta e do tipo dela.
  defp validate_account(_bank, "institucional"), do: :ok

  defp validate_account(bank, _transfer_type) do
    with :ok <- validate_present(bank, "account", "receiver.bank.account"),
         :ok <- validate_present(bank, "account_type", "receiver.bank.account_type") do
      Params.validate_member(
        Map.get(bank, "account_type"),
        @account_types,
        "receiver.bank.account_type",
        @path
      )
    end
  end

  defp validate_institutional("institucional", body) do
    with :ok <- validate_present(body, "hist", "hist") do
      validate_present(body, "cit", "cit")
    end
  end

  defp validate_institutional(_transfer_type, _body), do: :ok

  defp validate_conciliation_id(nil), do: :ok

  defp validate_conciliation_id(conciliation_id) do
    if is_binary(conciliation_id) and
         Regex.match?(~r/\A[A-Za-z0-9]{1,#{@max_conciliation_id_length}}\z/, conciliation_id) do
      :ok
    else
      validation_error(
        "conciliation_id deve ter até 35 caracteres, só letras e dígitos, sem caracteres especiais."
      )
    end
  end

  defp validate_present(map, key, field) do
    if Params.present?(map, key), do: :ok, else: validation_error("#{field} é obrigatório.")
  end

  defp validation_error(message), do: {:error, Error.validation(message, @path)}

  defp list_params(filter_opts) do
    params =
      filter_opts
      |> Pagination.params(@max_limit)
      |> Params.put_present(:query, Keyword.get(filter_opts, :query))

    Enum.reduce(@date_filters, params, fn filter, params ->
      Params.put_present(
        params,
        filter,
        filter_opts |> Keyword.get(filter) |> Params.format_local_datetime()
      )
    end)
  end

  defp item_path(transfer_request_id),
    do: "#{@path}/#{Client.encode_path_segment(transfer_request_id)}"
end
