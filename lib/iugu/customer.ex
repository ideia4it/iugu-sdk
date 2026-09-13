defmodule Iugu.Customer do
  @moduledoc """
  Cliente da Iugu e as formas de pagamento salvas dele.

  Um cliente pertence à conta do token que o criou: a mestre e cada subconta
  têm cadastros separados, e o mesmo CPF precisa ser criado de novo em cada
  conta que vai cobrá-lo. Ele serve a três coisas: ligar faturas e cobranças
  a uma pessoa (`customer_id`), guardar cartões para cobrar de novo sem
  tokenizar (`customer_payment_method_id`) e, com um cartão padrão, deixar a
  Iugu cobrar sozinha as faturas dele no vencimento.

  ## Qual token

  Nenhuma rota daqui exige assinatura RSA nem `user_token`. Tudo usa o
  `live_api_token` ou `test_api_token` da conta dona do cliente: o padrão do
  SDK para a mestre, `api_token:` para uma subconta.

  ## Cadastro e CEP

  `email` e `name` são obrigatórios; `phone_prefix` é obrigatório com
  `phone`; `number` é obrigatório com `zip_code`. O CEP dispara uma consulta
  de endereço na Iugu: "caso não seja retornado os dados do endereço completo
  do cliente, será apresentado um erro ao tentar criar o cliente informando
  que falta alguma informação". Por isso, com `zip_code`, mande também
  `street` e `district` quando os tiver: cidade de CEP único falha na
  consulta e o 422 vem `street: não pode ficar em branco`. `cpf_cnpj` só é
  obrigatório para boleto registrado; "Aceito o campo alfanumérico apenas
  para CNPJ". `phone` e `phone_prefix` voltam como string mesmo que entrem
  como inteiro.

  ## Listagem tem janela

  `GET /v1/customers` não devolve o cadastro inteiro: "sem filtro de data,
  retorna apenas registros atualizados nos últimos 7 dias"; entre
  `updated_since` e `updated_until` a janela máxima é 90 dias (faltando um, o
  outro é ajustado); e `start > 100` exige `updated_since` ou
  `created_at_from`, senão 400 "Paginação profunda (start > 100) requer ao
  menos um filtro identificador". `list/1` recusa localmente essa última
  combinação e `stream/1` exige um dos dois filtros por isso. `query`
  procura em e-mail, nome, notas e variáveis customizadas, e "necessário usar
  paginação": o SDK completa `limit` com 100 quando falta. Fim da lista é
  página menor que `limit`; `totalItems` não serve (a documentação o define
  como o tamanho da página e o exemplo mostra 57 ao lado de 3 itens).

  ## Cartão salvo e cartão padrão

  Uma forma de pagamento nasce de um token de uso único
  (`Iugu.PaymentToken`) com `create_payment_method/3`, e a partir
  daí "poderá ser utilizado infinitas vezes" via `customer_payment_method_id`
  em `Iugu.Charge.create/2`. Só `credit_card` existe; só a
  `description` pode ser editada, "para alterar o cartão, crie uma nova forma
  e remova a antiga". A listagem é um array cru, sem paginação; buscar um id
  inexistente é 404 `Customer payment method Not Found`. O webhook
  `customer_payment_method.new` dispara na criação; não há evento de edição
  nem remoção.

  O cartão padrão (`set_as_default: true` na criação, ou
  `set_default_payment_method/3`) faz a Iugu cobrar "as faturas geradas para
  este cliente, na data do vencimento ou após vencimento", permite
  `Iugu.Charge.create/2` só com `customer_id`, e é exigido por
  assinaturas com `only_on_charge_success`. Mandar `nil` desvincula. Cada
  cartão aceita "até cinco (5) tentativas de pagamento" por mês.

  ## Compartilhar cartão entre subcontas

  "Só é possível compartilhar o cartão salvo entre subcontas se a forma de
  pagamento tiver sido criada na conta mestre." O roteiro documentado, cada
  passo com o token da conta indicada:

    1. `create/2` do cliente na mestre e `create_payment_method/3` nele
    2. `get/2` do cliente na mestre para copiar os dados exatos
    3. `create/2` na subconta "exatamente com os MESMOS dados"
    4. `share_payment_methods_from/3` na subconta, apontando para o id do
       cliente da mestre (`proxy_payments_from_customer_id`)

  Depois a subconta cobra com o `customer_payment_method_id` do cliente da
  mestre. Não existe rota própria de compartilhamento; é um campo do PUT.

  ## O que não está confirmado

    * a mensagem exata do 400 ao remover cliente com assinatura, e o que uma
      segunda remoção responde (provavelmente `Not Found`)
    * se `payment_methods` dentro do cliente vem preenchido (é `[]` em todos
      os exemplos; use `list_payment_methods/2`)
    * o efeito de remover o cartão padrão sobre `default_payment_method_id`
      e se a remoção é recusada quando uma assinatura o usa
    * se um token `test: true` pode ser salvo numa conta live (por analogia
      com a cobrança, não)
    * no compartilhamento, se a subconta deve mandar o próprio `customer_id`
      junto do `customer_payment_method_id` da mestre, e se os cartões
      compartilhados aparecem em `list_payment_methods/2` da subconta
    * se `fingerprint` é estável entre contas (serve para achar o mesmo
      cartão físico dentro de uma conta)
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Pagination
  alias Iugu.Params
  alias Iugu.Response

  @customers_path "/v1/customers"
  @max_limit 100
  @deep_pagination_start 100

  @create_fields [
    :email,
    :name,
    :notes,
    :phone,
    :phone_prefix,
    :cpf_cnpj,
    :cc_emails,
    :zip_code,
    :number,
    :street,
    :district,
    :city,
    :state,
    :complement,
    :custom_variables
  ]
  @update_fields [:default_payment_method_id, :proxy_payments_from_customer_id | @create_fields]
  @payment_method_fields [:description, :token, :set_as_default]

  @list_filters [
    :start,
    :limit,
    :created_at_from,
    :created_at_to,
    :updated_since,
    :updated_until,
    :query
  ]
  @datetime_filters [:created_at_from, :created_at_to, :updated_since, :updated_until]
  @deep_pagination_filters [:updated_since, :created_at_from]

  @type customer :: map()
  @type payment_method :: map()

  @type page :: %{customers: [customer()], page_info: Pagination.page_info()}

  @type card :: %{
          brand: String.t() | nil,
          holder_name: String.t() | nil,
          display_number: String.t() | nil,
          bin: String.t() | nil,
          last_digits: String.t() | nil,
          month: integer() | nil,
          year: integer() | nil,
          fingerprint: String.t() | nil,
          issuer: String.t() | nil,
          foreign_card?: boolean() | nil
        }

  @doc """
  Cria um cliente na conta do token.

  `attrs` usa os nomes da API em átomo ou string: `:email` e `:name`
  (obrigatórios), `:notes`, `:phone` e `:phone_prefix` (juntos), `:cpf_cnpj`,
  `:cc_emails` (lista ou string separada por vírgula), `:zip_code` com
  `:number` (e `:street`, `:district`, `:city`, `:state`, `:complement`) e
  `:custom_variables` (lista de `%{name, value}`). Chave fora da lista
  levanta `ArgumentError`.

  Antes da chamada o SDK recusa, com `kind: :validation, status: nil`, o que
  a Iugu recusaria com 422: `email` ou `name` ausentes, `phone` sem
  `phone_prefix`, `zip_code` sem `number`. O que a Iugu recusa vem por campo
  (`email: is invalid.`, `cpf_cnpj: is invalid.`, `street: não pode ficar em
  branco.`). A resposta é o cliente cru, com `id`.

  A rota está na lista das que aceitam `Idempotency-Key`; com a opção
  `:idempotency_key` o header entra e o retry liga (`:transient`), e a
  repetição da mesma chave responde 409 com o `resource_id` do cliente já
  criado. Sem a chave a chamada nunca repete: um timeout pode ter criado o
  cliente, e a Iugu não recusa dois clientes com o mesmo e-mail.
  """
  @spec create(map(), keyword()) :: {:ok, customer()} | {:error, Error.t()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    attrs = normalize_attrs(attrs, @create_fields)
    {idempotency_key, req_opts} = Keyword.pop(opts, :idempotency_key)

    with :ok <- Params.validate_present(attrs, [:email, :name], @customers_path),
         :ok <- validate_pairs(attrs, @customers_path) do
      Client.post(
        @customers_path,
        build_body(attrs),
        Client.idempotency_options(req_opts, idempotency_key)
      )
    end
  end

  @doc """
  Lê um cliente pelo id.

  A Iugu documenta o "não encontrado" desta rota como **400**
  `{"errors": "Customer Not Found"}`, não 404, então ele chega como
  `kind: :validation` com a mensagem preservada; `not_found?/1` reconhece
  as duas formas.
  """
  @spec get(String.t(), keyword()) :: {:ok, customer()} | {:error, Error.t()}
  def get(customer_id, opts \\ []) when is_binary(customer_id) do
    Client.get(customer_path(customer_id), opts)
  end

  @doc """
  Lista os clientes da conta, do mais recente ao mais antigo, até 100 por
  página. Leia "Listagem tem janela" no moduledoc.

  Filtros em opções: `:start`, `:limit` (preso a 100), `:created_at_from`,
  `:created_at_to`, `:updated_since`, `:updated_until` (`DateTime`,
  convertido para o horário de São Paulo, ou string já no formato
  `AAAA-MM-DDThh:mm:ss-03:00`) e `:query`. `start` acima de 100 sem
  `updated_since` nem `created_at_from` é recusado aqui, porque a Iugu
  responde 400. Devolve `%{customers, page_info}`.
  """
  @spec list(keyword()) :: {:ok, page()} | {:error, Error.t()}
  def list(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, @list_filters)

    with :ok <- validate_deep_pagination(filter_opts),
         params = list_params(filter_opts),
         {:ok, body} <- Client.get(@customers_path, Keyword.put(req_opts, :params, params)) do
      {:ok,
       %{
         customers: Response.items(body),
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

  Exige `:updated_since` ou `:created_at_from`: sem um deles a Iugu recusa a
  segunda página (`start > 100`) com 400, e a listagem sem filtro só cobre os
  últimos 7 dias de qualquer forma. Para na primeira página menor que
  `limit`, sem olhar `totalItems`, e levanta o `Iugu.Error` da
  primeira página que falhar.
  """
  @spec stream(keyword()) :: Enumerable.t()
  def stream(opts) do
    unless Enum.any?(@deep_pagination_filters, &Keyword.has_key?(opts, &1)) do
      raise ArgumentError,
            "stream/1 precisa de updated_since ou created_at_from: sem um deles a Iugu recusa start > 100 com 400."
    end

    {page_opts, other_opts} = Keyword.split(opts, [:start, :limit])

    Pagination.stream(
      fn stream_page_opts ->
        with {:ok, page} <- list(Keyword.merge(other_opts, stream_page_opts)) do
          {:ok, page.customers}
        end
      end,
      ["items"],
      Keyword.put(page_opts, :max_limit, @max_limit)
    )
  end

  @doc """
  Altera um cliente. "Quaisquer parâmetros não informados não serão
  alterados."

  Aceita os campos de `create/2`, nenhum obrigatório, mais
  `:default_payment_method_id` (id de uma forma de pagamento do cliente, ou
  `nil` para desvincular o cartão das cobranças automáticas; o `nil` sai
  como `null` de propósito) e `:proxy_payments_from_customer_id` (veja
  `share_payment_methods_from/3`). Para remover uma variável customizada,
  mande `%{name: "chave", _destroy: true}` em `:custom_variables`.
  """
  @spec update(String.t(), map(), keyword()) :: {:ok, customer()} | {:error, Error.t()}
  def update(customer_id, attrs, opts \\ []) when is_binary(customer_id) and is_map(attrs) do
    path = customer_path(customer_id)
    attrs = normalize_attrs(attrs, @update_fields)

    with :ok <- validate_pairs(attrs, path) do
      Client.put(path, build_body(attrs), opts)
    end
  end

  @doc """
  Define (ou, com `nil`, remove) a forma de pagamento padrão do cliente.

  É `update/3` com `default_payment_method_id`. Com um cartão padrão, "vai
  fazer cobranças automáticas das faturas geradas para este cliente, na data
  do vencimento ou após vencimento", e `Iugu.Charge.create/2` passa
  a aceitar só `customer_id`.
  """
  @spec set_default_payment_method(String.t(), String.t() | nil, keyword()) ::
          {:ok, customer()} | {:error, Error.t()}
  def set_default_payment_method(customer_id, payment_method_id, opts \\ [])
      when is_binary(customer_id) and (is_binary(payment_method_id) or is_nil(payment_method_id)) do
    update(customer_id, %{default_payment_method_id: payment_method_id}, opts)
  end

  @doc """
  Faz um cliente da subconta usar os cartões de um cliente da conta mestre.

  `PUT /v1/customers/{subaccount_customer_id}` com
  `proxy_payments_from_customer_id`, chamado com o token da **subconta**. O
  cliente da subconta precisa ter sido criado "exatamente com os MESMOS
  dados" do da mestre, e o cartão precisa ter nascido na mestre; um cartão
  criado na subconta não se compartilha. A resposta ecoa o campo preenchido.
  """
  @spec share_payment_methods_from(String.t(), String.t(), keyword()) ::
          {:ok, customer()} | {:error, Error.t()}
  def share_payment_methods_from(subaccount_customer_id, master_customer_id, opts \\ [])
      when is_binary(subaccount_customer_id) and is_binary(master_customer_id) do
    update(
      subaccount_customer_id,
      %{proxy_payments_from_customer_id: master_customer_id},
      opts
    )
  end

  @doc """
  Remove um cliente para sempre. "Não permite remover clientes com
  assinaturas vinculadas."

  A resposta é o cliente removido. Sem retry: uma segunda remoção
  provavelmente responde `Not Found`, mas não está documentado.
  """
  @spec delete(String.t(), keyword()) :: {:ok, customer()} | {:error, Error.t()}
  def delete(customer_id, opts \\ []) when is_binary(customer_id) do
    Client.delete(customer_path(customer_id), opts)
  end

  @doc """
  Salva um cartão no cliente a partir de um token de uso único.

  `attrs`: `:token` e `:description` (apelido do cartão) obrigatórios,
  `:set_as_default` para torná-lo o cartão padrão na mesma chamada. O token
  é consumido aqui, com sucesso ou falha (`token: Esse token já foi usado.`
  na reutilização; `item_type: não é suportado. (Métodos suportados:
  credit_card)` para token inválido). Só cartão de crédito existe, e só via
  token: a rota não recebe os dados do cartão em claro.

  A resposta é a forma de pagamento crua (`id`, `description`, `item_type`,
  `customer_id`, `data`); `card/1` lê os dados do cartão dela.
  """
  @spec create_payment_method(String.t(), map(), keyword()) ::
          {:ok, payment_method()} | {:error, Error.t()}
  def create_payment_method(customer_id, attrs, opts \\ [])
      when is_binary(customer_id) and is_map(attrs) do
    path = payment_methods_path(customer_id)
    attrs = normalize_attrs(attrs, @payment_method_fields)

    with :ok <- Params.validate_present(attrs, [:token, :description], path) do
      Client.post(path, build_body(attrs), opts)
    end
  end

  @doc """
  Lista as formas de pagamento do cliente.

  Sem paginação: a resposta é um array cru, que volta como lista.
  """
  @spec list_payment_methods(String.t(), keyword()) ::
          {:ok, [payment_method()]} | {:error, Error.t()}
  def list_payment_methods(customer_id, opts \\ []) when is_binary(customer_id) do
    with {:ok, body} <- Client.get(payment_methods_path(customer_id), opts) do
      {:ok, Response.items(body)}
    end
  end

  @doc "Lê uma forma de pagamento. Inexistente é 404 `Customer payment method Not Found`."
  @spec get_payment_method(String.t(), String.t(), keyword()) ::
          {:ok, payment_method()} | {:error, Error.t()}
  def get_payment_method(customer_id, payment_method_id, opts \\ [])
      when is_binary(customer_id) and is_binary(payment_method_id) do
    Client.get(payment_method_path(customer_id, payment_method_id), opts)
  end

  @doc """
  Altera o apelido de uma forma de pagamento, o único campo editável.

  Os dados do cartão não mudam: para trocar o cartão, crie outra forma de
  pagamento e remova esta.
  """
  @spec update_payment_method(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, payment_method()} | {:error, Error.t()}
  def update_payment_method(customer_id, payment_method_id, description, opts \\ [])
      when is_binary(customer_id) and is_binary(payment_method_id) and is_binary(description) do
    Client.put(
      payment_method_path(customer_id, payment_method_id),
      %{"description" => description},
      opts
    )
  end

  @doc """
  Remove uma forma de pagamento para sempre. A resposta é o objeto removido.

  O efeito sobre `default_payment_method_id` quando era o cartão padrão
  **não está documentado**; `set_default_payment_method/3` com o novo cartão
  (ou `nil`) deixa o cadastro num estado conhecido.
  """
  @spec delete_payment_method(String.t(), String.t(), keyword()) ::
          {:ok, payment_method()} | {:error, Error.t()}
  def delete_payment_method(customer_id, payment_method_id, opts \\ [])
      when is_binary(customer_id) and is_binary(payment_method_id) do
    Client.delete(payment_method_path(customer_id, payment_method_id), opts)
  end

  @doc "Id da forma de pagamento padrão do cliente, ou `nil`."
  @spec default_payment_method_id(customer()) :: String.t() | nil
  def default_payment_method_id(customer) when is_map(customer),
    do: Map.get(customer, "default_payment_method_id")

  @doc """
  Se o erro é o "não encontrado" de cliente ou forma de pagamento, nas duas
  formas que a Iugu usa: 404 de verdade e 400 `Customer Not Found`.
  """
  @spec not_found?(Error.t()) :: boolean()
  def not_found?(%Error{kind: :not_found}), do: true

  def not_found?(%Error{kind: :validation, status: 400, messages: messages}) do
    Enum.any?(messages, &String.ends_with?(&1, "Not Found"))
  end

  def not_found?(%Error{}), do: false

  @doc """
  Dados do cartão de uma forma de pagamento, lidos de `data`.

  Tolera as variações documentadas: `year` e `month` como inteiro ou string
  numérica, `foreign_card` como `"t"`/`"f"` (texto de booleano do Postgres),
  `last_digits` ausente (derivado de `display_number`). `fingerprint`
  identifica o mesmo cartão físico entre tokens diferentes na mesma conta.
  """
  @spec card(payment_method()) :: card() | nil
  def card(payment_method) when is_map(payment_method) do
    case Map.get(payment_method, "data") do
      %{} = data ->
        %{
          brand: Map.get(data, "brand"),
          holder_name: Map.get(data, "holder_name"),
          display_number: Response.get_any(data, ["display_number", "masked_number"]),
          bin: Response.get_any(data, ["bin", "first_digits"]),
          last_digits: last_digits(data),
          month: Response.integer(data, ["month"]),
          year: Response.integer(data, ["year"]),
          fingerprint: Map.get(data, "fingerprint"),
          issuer: Map.get(data, "issuer"),
          foreign_card?: foreign_card(Map.get(data, "foreign_card"))
        }

      _other ->
        nil
    end
  end

  defp last_digits(data) do
    case Response.get_any(data, ["last_digits", "display_number", "masked_number"]) do
      digits when is_binary(digits) -> digits |> String.split("-") |> List.last()
      _other -> nil
    end
  end

  defp foreign_card("t"), do: true
  defp foreign_card("f"), do: false
  defp foreign_card(value) when is_boolean(value), do: value
  defp foreign_card(_value), do: nil

  # As chaves viram os átomos conhecidos para a whitelist pegar erros de
  # digitação; valores nil são mantidos, porque um default_payment_method_id: nil
  # explícito precisa sair como null para desvincular o cartão.
  defp normalize_attrs(attrs, fields) do
    Map.new(attrs, fn {key, value} -> {Params.field!(key, fields, "cliente"), value} end)
  end

  defp build_body(attrs) do
    Map.new(attrs, fn
      {:cc_emails, emails} -> {"cc_emails", join_emails(emails)}
      {:custom_variables, variables} -> {"custom_variables", stringify_variables(variables)}
      {key, value} -> {Atom.to_string(key), value}
    end)
  end

  defp join_emails(emails) when is_list(emails), do: Enum.join(emails, ", ")
  defp join_emails(emails), do: emails

  defp stringify_variables(variables) when is_list(variables) do
    Enum.map(variables, fn variable ->
      Map.new(variable, fn {key, value} -> {to_string(key), value} end)
    end)
  end

  defp stringify_variables(variables), do: variables

  defp validate_pairs(attrs, path) do
    cond do
      Params.present?(attrs, :phone) and not Params.present?(attrs, :phone_prefix) ->
        {:error, Error.validation("phone_prefix é obrigatório quando phone é informado.", path)}

      Params.present?(attrs, :zip_code) and not Params.present?(attrs, :number) ->
        {:error, Error.validation("number é obrigatório quando zip_code é informado.", path)}

      true ->
        :ok
    end
  end

  defp validate_deep_pagination(filter_opts) do
    start = Keyword.get(filter_opts, :start, 0)

    if start > @deep_pagination_start and
         not Enum.any?(@deep_pagination_filters, &Keyword.has_key?(filter_opts, &1)) do
      {:error,
       Error.validation(
         "Paginação profunda (start > 100) exige updated_since ou created_at_from.",
         @customers_path
       )}
    else
      :ok
    end
  end

  defp list_params(filter_opts) do
    params =
      filter_opts
      |> Pagination.params(@max_limit)
      |> Params.put_present(:query, Keyword.get(filter_opts, :query))
      |> put_query_limit()

    Enum.reduce(@datetime_filters, params, fn filter, params ->
      Params.put_present(
        params,
        filter,
        filter_opts |> Keyword.get(filter) |> Params.format_local_datetime()
      )
    end)
  end

  # "Ao usar este parâmetro, necessário usar paginação (limit, start, etc)."
  defp put_query_limit(%{query: _query} = params), do: Map.put_new(params, :limit, @max_limit)
  defp put_query_limit(params), do: params

  defp customer_path(customer_id),
    do: "#{@customers_path}/#{Client.encode_path_segment(customer_id)}"

  defp payment_methods_path(customer_id), do: "#{customer_path(customer_id)}/payment_methods"

  defp payment_method_path(customer_id, payment_method_id) do
    "#{payment_methods_path(customer_id)}/#{Client.encode_path_segment(payment_method_id)}"
  end
end
