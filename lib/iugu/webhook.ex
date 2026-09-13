defmodule Iugu.Webhook do
  @moduledoc """
  Gatilhos da Iugu: cadastro, consulta, reenvio e logs de webhook.

  A Iugu chama webhook de "gatilho". Um gatilho é um par `(event, url)`
  guardado numa conta (mestre ou subconta): quando o evento acontece, a Iugu
  faz um POST na URL. `event: "all"` assina tudo de uma vez numa URL só; fora
  dele, escutar dez eventos são dez gatilhos, e é por isso que existe
  `Iugu.Webhook.Sync`.

  ## Token

  O gatilho pertence à conta cujo token o criou: "Caso utilize o gatilho na
  conta mestre, enviar api_token da conta mestre. Se o gatilho estiver na
  subconta, enviar o api_token da subconta." É sempre o `live_api_token` ou
  `test_api_token` da conta, nunca `user_token` nem `master_token`. Nenhuma
  rota deste módulo exige a assinatura RSA. Subconta ainda não verificada só
  aceita o `test_api_token`; com o `live_api_token` a resposta é 401.

  Se um gatilho criado com `test_api_token` dispara só para objetos de teste
  e um criado com `live_api_token` só para os de produção **não está
  documentado**; a documentação marca dois eventos como exclusivos de
  produção (`invoice.installment_released` e `invoice.released`), o que
  sugere que o modo de teste entrega os demais.

  ## Limite e ausência de idempotência

  "A iugu possui uma limitação de configuração de 20 gatilhos, sendo iguais
  ou não." A tabela de erros fala em 30 (`account: não pode ter mais de 30
  gatilhos`). O SDK trabalha com 20 e trata o 422 como a palavra final.
  "Iguais ou não" quer dizer que gatilho repetido conta e **é aceito**: não
  há chave de idempotência nem deduplicação, e dois `create/2` iguais criam
  dois gatilhos, cada um entregando o mesmo evento. Só `Sync.sync/2` confere
  o que já existe antes de criar.

  Não há paginação em `list/1` nem em `list_logs/2`, e não há limite de
  requisições documentado para nenhuma destas rotas.

  ## O que a Iugu manda para a nossa URL

  O corpo é `application/x-www-form-urlencoded`, **não JSON**, com chaves no
  estilo Rails: `event=invoice.created&data[id]=...&data[status]=...`. O
  `Plug.Parsers.URLENCODED` já entrega isso como `%{"event" => _, "data" =>
  %{...}}`; `Iugu.Webhook.Event` normaliza o resto (algumas tabelas
  documentam as chaves sem o prefixo `data[]`, outras trazem o nome do evento
  em `data[event]`). Todo valor chega como string, booleano incluído
  (`"true"`, `"false"` ou vazio).

  A entrega não tem assinatura. A única conferência é o `authorization` que
  você cadastra no gatilho e a Iugu devolve no header `Authorization` de cada
  chamada ("Grave uma chave / key para usar como Basic Authentication na
  validação do recebimento dos gatilhos"); se ela manda o valor cru ou
  embrulhado em `Basic base64(...)` **não está documentado**, e
  `Event.authorized?/2` aceita os dois. O IP de saída para allowlist de
  firewall é `98.82.243.132` (o antigo `54.207.210.151` foi aposentado em
  04/08/2025). O `authorization` volta em claro em toda consulta, então ele é
  recuperável pela API; trate-o como segredo do nosso lado mesmo assim.

  A política de retentativa automática **não está documentada** em nenhuma
  página da Iugu. O que existe é o caminho manual: `list_logs/2` mostra cada
  entrega com o HTTP que respondemos, `force_retry/2` repete uma, e
  `resend_by_period/3` repete todas de uma janela de até 3 dias. Os dois
  reenviam o payload original tal qual, então o receptor precisa ser
  idempotente (`Event.idempotency_key/1`) e responder 2xx rápido, processando
  depois.

  ## O que não está confirmado

    * se `active` pode ser alterado pela API (nenhum parâmetro documentado o
      liga ou desliga; `create/2` e `update/3` mandam `active` quando o
      chamador passa, e a Iugu pode ignorar)
    * se `authorization: nil` ou `""` em `update/3` limpa o segredo
    * o formato do 404 de id desconhecido em `get/2`, `update/3` e `delete/2`
      (por analogia com os logs, `{"errors": "..."}`), e se um segundo
      `delete/2` do mesmo id é 404
    * se `initial_date`, `final_date` e `event` são obrigatórios em
      `resend_by_period/3` e se a janela precisa estar toda no passado há
      mais de 3 dias ("a consulta só pode ser feita para logs anteriores a
      três dias")
    * se `GET /v1/web_hook_logs/{id}` aceita id de outro objeto além de
      fatura, o valor de `status` numa entrega que falhou e o de `error` sem
      resposta HTTP
    * os payloads de `invoice.partially_refunded`, `invoice.refund_reverted`,
      `invoice.rejected`, `transfer_request.ted_status_changed`,
      `transfer_request.refunded`, `transfer_request.partially_refunded` e
      `pix_key.status_changed`, que estão em `list_events/1` mas não têm
      página de documentação
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Params
  alias Iugu.Response
  alias Iugu.Webhook.Event
  alias Plug.Conn.Query

  @path "/v1/web_hooks"
  @logs_path "/v1/web_hook_logs"
  @max_resend_window_days 3
  @outbound_ip "98.82.243.132"

  @invoice_events [
    "invoice.created",
    "invoice.status_changed",
    "invoice.refund",
    "invoice.payment_failed",
    "invoice.dunning_action",
    "invoice.due",
    "invoice.installment_released",
    "invoice.released",
    "invoice.bank_slip_status",
    "invoice.partially_refunded",
    "invoice.refund_reverted",
    "invoice.rejected",
    "invoice.split_released",
    "invoice.split_status_changed",
    "invoice.split_installment_released"
  ]

  @subscription_events [
    "subscription.suspended",
    "subscription.activated",
    "subscription.created",
    "subscription.renewed",
    "subscription.expired",
    "subscription.changed"
  ]

  @kyc_events [
    "referrals.verification",
    "referrals.bank_verification",
    "referrals.document_status_change"
  ]

  @withdraw_events ["withdraw_request.created", "withdraw_request.status_changed"]

  @transfer_request_events [
    "transfer_request.status_changed",
    "transfer_request.pix_status_changed",
    "transfer_request.ted_status_changed",
    "transfer_request.rejected",
    "transfer_request.done",
    "transfer_request.refunded",
    "transfer_request.partially_refunded"
  ]

  @account_transfer_events ["transfer.debited", "transfer.credited"]

  @deposit_events ["deposit.pix_status_changed", "deposit.ted_status_changed"]

  @other_events [
    "customer_payment_method.new",
    "advancement_request.advancement_status",
    "advancement_request.simulation_status",
    "payment_request.created",
    "payment_request.status_changed",
    "pix_key.status_changed"
  ]

  @events ["all"] ++
            @invoice_events ++
            @subscription_events ++
            @kyc_events ++
            @withdraw_events ++
            @transfer_request_events ++
            @account_transfer_events ++ @deposit_events ++ @other_events

  @type trigger :: %{
          id: String.t() | nil,
          url: String.t() | nil,
          event: String.t() | nil,
          authorization: String.t() | nil,
          active: boolean() | nil,
          body: map()
        }

  @type log :: %{
          id: String.t() | nil,
          web_hook_id: String.t() | nil,
          status: String.t() | nil,
          http_status: integer() | nil,
          loggable_id: String.t() | nil,
          loggable_type: String.t() | nil,
          payload: map(),
          event: Event.t() | nil,
          body: map()
        }

  @doc """
  Catálogo de eventos documentados, com `"all"` na frente.

  É uma cópia local, não a verdade: "Determinados gatilhos não ficam
  disponíveis para determinados tipos de contas contratada", e a lista muda
  sem aviso. Para o valor corrente da conta use `list_events/1`. Esta serve
  para montar uma assinatura sem gastar chamada e para escolher eventos sem
  credencial.

  Inclui `referrals.document_status_change`, que a página de KYC documenta
  mas o exemplo de `list_events/1` não devolve; a disponibilidade dele por
  tipo de conta **não está documentada**.
  """
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "Eventos de fatura (`invoice.*`)."
  @spec invoice_events() :: [String.t()]
  def invoice_events, do: @invoice_events

  @doc "Eventos de assinatura (`subscription.*`)."
  @spec subscription_events() :: [String.t()]
  def subscription_events, do: @subscription_events

  @doc """
  Eventos de verificação de subconta (`referrals.*`): KYC, domicílio bancário
  e documentos.

  Devem ser configurados na conta que os recebe. Se um gatilho na conta mestre
  recebe os `referrals.*` de todas as subcontas **não está documentado**; o
  payload traz `data[account_id]` como "ID da Conta que enviou a
  Verificação", o que sugere que sim, e é assim que os marketplaces o usam.
  """
  @spec kyc_events() :: [String.t()]
  def kyc_events, do: @kyc_events

  @doc "Eventos de saque para o domicílio bancário (`withdraw_request.*`)."
  @spec withdraw_events() :: [String.t()]
  def withdraw_events, do: @withdraw_events

  @doc """
  Eventos de transferência: Pix e TED para terceiros (`transfer_request.*`)
  e transferência entre contas Iugu (`transfer.debited`, `transfer.credited`).
  """
  @spec transfer_events() :: [String.t()]
  def transfer_events, do: @transfer_request_events ++ @account_transfer_events

  @doc "Eventos de depósito recebido por Pix ou TED (`deposit.*`)."
  @spec deposit_events() :: [String.t()]
  def deposit_events, do: @deposit_events

  @doc "IP de saída da Iugu para allowlist de firewall."
  @spec outbound_ip() :: String.t()
  def outbound_ip, do: @outbound_ip

  @doc """
  Eventos que a conta pode assinar, perguntados à API.

  `GET /v1/web_hooks/supported_events` devolve um array de strings, `"all"`
  incluído. A lista depende do tipo de conta, então é ela, e não `events/0`,
  que decide o que `create/2` aceita.
  """
  @spec list_events(keyword()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def list_events(opts \\ []) do
    with {:ok, body} <- Client.get("#{@path}/supported_events", opts) do
      {:ok, body |> Response.items() |> Enum.filter(&is_binary/1)}
    end
  end

  @doc """
  Cria um gatilho na conta do token.

  Campos:

    * `:event` (obrigatório) - um de `list_events/1` ou `"all"`. Evento fora
      da lista é 422 `event: is invalid.`; o SDK não confere contra `events/0`
      porque a lista é por conta
    * `:url` (obrigatório) - precisa começar com `https://` ("A URL deve ser
      acompanhada de https://..."), senão 422 `url: não é uma url válida.`;
      conferido antes da chamada
    * `:authorization` - valor que a Iugu vai devolver no header
      `Authorization` **das chamadas para a nossa URL**, não a credencial dela
    * `:active` - só sai quando informado; se a API o respeita **não está
      documentado**

  A resposta é 200, não 201, com o gatilho normalizado. Não há idempotência:
  repetir a chamada cria um segundo gatilho idêntico, e o vigésimo primeiro
  é 422. Sem retry por isso.
  """
  @spec create(map(), keyword()) :: {:ok, trigger()} | {:error, Error.t()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    body = build_body(attrs)

    with :ok <- validate_present(body, "event"),
         :ok <- validate_present(body, "url"),
         :ok <- validate_url(Map.get(body, "url")),
         {:ok, response} <- Client.post(@path, body, opts) do
      {:ok, normalize(response)}
    end
  end

  @doc """
  Altera um gatilho (`PUT /v1/web_hooks/{id}`), token da conta dona.

  Atualização parcial: só as chaves presentes em `attrs` (`:event`, `:url`,
  `:authorization`, `:active`) vão no corpo, com a mesma validação de
  `create/2`. Se `authorization: nil` limpa o segredo **não está
  documentado**; o SDK manda `null` quando a chave está presente com `nil`.
  """
  @spec update(String.t(), map(), keyword()) :: {:ok, trigger()} | {:error, Error.t()}
  def update(id, attrs, opts \\ []) when is_binary(id) and is_map(attrs) do
    body = build_body(attrs)

    with :ok <- validate_url(Map.get(body, "url")),
         {:ok, response} <- Client.put(item_path(id), body, opts) do
      {:ok, normalize(response)}
    end
  end

  @doc "Consulta um gatilho pelo id."
  @spec get(String.t(), keyword()) :: {:ok, trigger()} | {:error, Error.t()}
  def get(id, opts \\ []) when is_binary(id) do
    with {:ok, body} <- Client.get(item_path(id), opts) do
      {:ok, normalize(body)}
    end
  end

  @doc """
  Remove um gatilho. A resposta é o gatilho removido, não um 204.

  A remoção não está documentada como idempotente; um segundo `delete/2` do
  mesmo id provavelmente é 404.
  """
  @spec delete(String.t(), keyword()) :: {:ok, trigger()} | {:error, Error.t()}
  def delete(id, opts \\ []) when is_binary(id) do
    with {:ok, body} <- Client.delete(item_path(id), opts) do
      {:ok, normalize(body)}
    end
  end

  @doc """
  Lista os gatilhos da conta do token, sem paginação.

  A API não filtra: `:url` e `:event` são filtros locais, aplicados depois da
  resposta, e é o `:url` que permite ao `Sync` mexer só no que aponta para o
  nosso endereço. A referência mostra um objeto solto como exemplo onde o
  texto diz lista; o SDK aceita as duas formas.
  """
  @spec list(keyword()) :: {:ok, [trigger()]} | {:error, Error.t()}
  def list(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, [:url, :event])

    with {:ok, body} <- Client.get(@path, req_opts) do
      triggers =
        body
        |> triggers_in()
        |> Enum.map(&normalize/1)
        |> filter_by(:url, Keyword.get(filter_opts, :url))
        |> filter_by(:event, Keyword.get(filter_opts, :event))

      {:ok, triggers}
    end
  end

  @doc """
  Reenvia os gatilhos de um período (`GET /v1/web_hooks/resend`).

  `initial_date` e `final_date` são `Date`, enviadas como `AAAA-MM-DD`; a
  janela vai de zero a #{@max_resend_window_days} dias ("O maior intervalo
  permitido é de 3 dias", 400), conferida antes da chamada. `:event` filtra o
  evento a reenviar ("por enquanto, somente de invoices e transfer_request").
  Se a janela precisa estar toda há mais de 3 dias no passado **não está
  documentado**.

  É um GET com efeito: a Iugu responde `{"message": "Os gatilhos do período
  foram enviados para procesasamento, ..."}` (erro de grafia da API) e
  processa depois, repetindo cada entrega tal qual para a URL cadastrada
  hoje. Por isso não repete em falha transitória por padrão, ao contrário dos
  outros GET, e o receptor precisa ser idempotente.
  """
  @spec resend_by_period(Date.t(), Date.t(), keyword()) ::
          {:ok, %{message: String.t() | nil, body: term()}} | {:error, Error.t()}
  def resend_by_period(%Date{} = initial_date, %Date{} = final_date, opts \\ []) do
    {resend_opts, req_opts} = Keyword.split(opts, [:event])

    params =
      %{initial_date: Date.to_iso8601(initial_date), final_date: Date.to_iso8601(final_date)}
      |> Params.put_present(:event, Keyword.get(resend_opts, :event))

    with :ok <- validate_window(initial_date, final_date),
         {:ok, body} <-
           Client.get(
             "#{@path}/resend",
             req_opts |> Keyword.put(:params, params) |> Keyword.put_new(:retry, false)
           ) do
      {:ok, %{message: message_in(body), body: body}}
    end
  end

  @doc """
  Entregas registradas para uma fatura (`GET /v1/web_hook_logs/{invoice_id}`).

  Token da conta dona do gatilho (mestre ou subconta). Só o id de fatura está
  documentado no caminho (`loggable_type: "Invoice"`). Cada log traz o corpo
  exato que a Iugu postou, como mapa plano com chaves literais `"data[id]"`;
  aqui ele volta em `payload` já aninhado e em `event` como
  `Iugu.Webhook.Event` (`nil` quando o evento não é reconhecido).
  `http_status` é o que a nossa URL respondeu (`"200"` na API, inteiro aqui)
  e `status` é `"success"`; o valor numa falha **não está documentado**.
  """
  @spec list_logs(String.t(), keyword()) :: {:ok, [log()]} | {:error, Error.t()}
  def list_logs(invoice_id, opts \\ []) when is_binary(invoice_id) do
    with {:ok, body} <- Client.get(log_path(invoice_id), opts) do
      {:ok, body |> Response.items() |> Enum.map(&normalize_log/1)}
    end
  end

  @doc """
  Repete uma entrega pelo id do log (`GET /v1/web_hook_logs/{id}/retry`).

  O id é o `id` do log em `list_logs/2`, não o `web_hook_id`. A Iugu posta de
  novo o payload guardado na URL atual do gatilho. O 200 documentado é
  `{ "Hook reenviado!" }`, que **não é JSON válido**: a resposta é lida crua
  e qualquer 2xx é sucesso. Id desconhecido é 404 `{"errors": "Web hook log
  Not Found"}`. Sem retry por padrão, pelo mesmo motivo de
  `resend_by_period/3`.
  """
  @spec force_retry(String.t(), keyword()) ::
          {:ok, %{message: String.t()}} | {:error, Error.t()}
  def force_retry(log_id, opts \\ []) when is_binary(log_id) do
    req_opts =
      opts
      |> Keyword.put(:decode_body, false)
      |> Keyword.put_new(:retry, false)

    with {:ok, %Req.Response{body: body}} <-
           Client.request_raw(:get, "#{log_path(log_id)}/retry", req_opts) do
      {:ok, %{message: body |> to_string() |> String.trim()}}
    end
  end

  defp build_body(attrs) do
    Enum.reduce(attrs, %{}, fn {key, value}, body ->
      Map.put(body, field_name!(key), value)
    end)
  end

  defp field_name!(key) when key in [:event, :url, :authorization, :active],
    do: Atom.to_string(key)

  defp field_name!(key) when key in ["event", "url", "authorization", "active"], do: key

  defp field_name!(key) do
    raise ArgumentError,
          "campo desconhecido no gatilho: #{inspect(key)}. Use event, url, authorization ou active."
  end

  defp validate_present(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) and value != "" -> :ok
      _missing -> {:error, Error.validation("#{key} é obrigatório.", @path)}
    end
  end

  # A Iugu rejeita qualquer coisa que não seja https com um 422, então a
  # checagem é feita antes de gastar a chamada; uma url nil é aceitável numa
  # atualização parcial.
  defp validate_url(nil), do: :ok

  defp validate_url(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" ->
        :ok

      _other ->
        {:error, Error.validation("url deve ser uma URL válida começando com https://.", @path)}
    end
  end

  defp validate_window(initial_date, final_date) do
    days = Date.diff(final_date, initial_date)

    if days >= 0 and days <= @max_resend_window_days do
      :ok
    else
      {:error,
       Error.validation(
         "o período de reenvio vai de final_date igual a initial_date até #{@max_resend_window_days} dias depois.",
         "#{@path}/resend"
       )}
    end
  end

  # A referência documenta a listagem com um objeto solitário como exemplo
  # enquanto o texto diz lista; um trigger chegando sozinho não pode ser lido
  # como nenhum.
  defp triggers_in(body) when is_list(body), do: body
  defp triggers_in(%{"id" => _id} = trigger), do: [trigger]
  defp triggers_in(body), do: Response.items(body)

  defp filter_by(triggers, _key, nil), do: triggers
  defp filter_by(triggers, key, value), do: Enum.filter(triggers, &(Map.get(&1, key) == value))

  defp normalize(body) when is_map(body) do
    %{
      id: Map.get(body, "id"),
      url: Map.get(body, "url"),
      event: Map.get(body, "event"),
      authorization: Map.get(body, "authorization"),
      active: Map.get(body, "active"),
      body: body
    }
  end

  defp normalize(body),
    do: %{id: nil, url: nil, event: nil, authorization: nil, active: nil, body: body}

  defp normalize_log(body) when is_map(body) do
    payload = body |> Map.get("data", %{}) |> nest_form_keys()

    %{
      id: Map.get(body, "id"),
      web_hook_id: Map.get(body, "web_hook_id"),
      status: Map.get(body, "status"),
      http_status: Response.integer(body, ["error"]),
      loggable_id: Map.get(body, "loggable_id"),
      loggable_type: Map.get(body, "loggable_type"),
      payload: payload,
      event: event_in(payload),
      body: body
    }
  end

  # O log mantém plano o corpo de formulário postado, com chaves literais
  # "data[id]". Recodificar como query string e decodificar com Plug dá o mesmo
  # mapa aninhado que o receptor vê.
  defp nest_form_keys(%{} = flat) do
    flat
    |> Enum.filter(fn {_key, value} -> is_binary(value) end)
    |> URI.encode_query()
    |> Query.decode()
  end

  defp nest_form_keys(_other), do: %{}

  defp event_in(payload) do
    case Event.parse(payload) do
      {:ok, event} -> event
      {:error, :unsupported_event} -> nil
    end
  end

  defp message_in(%{"message" => message}) when is_binary(message), do: message
  defp message_in(_body), do: nil

  defp item_path(id), do: "#{@path}/#{Client.encode_path_segment(id)}"
  defp log_path(id), do: "#{@logs_path}/#{Client.encode_path_segment(id)}"
end
