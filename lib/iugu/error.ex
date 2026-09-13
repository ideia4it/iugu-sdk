defmodule Iugu.Error do
  @moduledoc """
  Erro devolvido por qualquer chamada do SDK da Iugu.

  A Iugu não tem um corpo de erro único. A chave `errors` chega em três
  formas, conforme a rota e o status:

      {"errors": "Account Not Found"}
      {"errors": ["Description não pode ficar em branco", "Api type não pode ficar em branco"]}
      {"errors": {"due_date": ["não pode ficar em branco", "não pode estar no passado"]}}

  A terceira é a do 422 de validação: cada chave é um campo (às vezes com
  ponto, como `items.price_cents` ou `splits.base`) e cada valor a lista de
  mensagens. `messages` achata isso em `"campo: mensagem"` para o log, e
  `fields` preserva o mapa para quem precisa apontar o erro no formulário
  certo, porque um 422 na criação de fatura é por campo.

  A transferência entre contas (`POST /v1/transfers`) usa o mesmo mapa por
  campo, mas sob a chave `message`, a quarta forma documentada:

      {"message": {"amount_cents": ["Saldo insuficiente"]}}
      {"message": {"receiver_account": ["não encontrado"]}}

  Ela é lida exatamente como o mapa em `errors`, então `messages` e `fields`
  separam "Saldo insuficiente" de "receiver_account: não encontrado" sem
  que o chamador precise abrir `body`.

  Algumas rotas respondem `{"success": false, "message": "..."}`, muitos 400
  vêm documentados como `{}` vazio, e o 401 não tem corpo documentado. A
  extração é tolerante: cai para o corpo cru quando não reconhece a forma, em
  vez de estourar.

  O `kind` separa o que a investigação trata de forma diferente:

    * `:unauthorized` (401) quase nunca é senha errada. A documentação lista
      cinco causas: subconta não verificada usando `live_api_token`, token
      pendente de aprovação do administrador, `api_token` onde a rota pede
      `user_token`, IP fora da lista permitida e token de outra conta.
    * `:not_found` só cobre o 404 de verdade. A Iugu devolve vários "Not
      Found" como 400 (`Api token Not Found`, `Customer Not Found`), que caem
      em `:validation` com a mensagem preservada.
    * `:validation` cobre 400, 409 (chave de idempotência repetida) e 422,
      incluindo as falhas de assinatura RSA (`Public Key Not Found`,
      `Invalid Elapsed Time`, `Invalid Signature`), que a tabela de erros
      documenta como 422.
    * `:rate_limited` é o 429 do modo de teste (50 requisições por minuto).
      Corpo e header `Retry-After` não estão documentados.
    * `:forbidden` não aparece em nenhuma página da documentação; fica aqui
      para não classificar um 403 real como inesperado.
    * `:declined` é a recusa do cartão na cobrança direta. `POST /v1/charge`
      responde **HTTP 200** com `"success": false` quando o emissor nega, e
      `POST /v1/zero_auth` responde 422 com `"valid": false`; nos dois casos
      o código de retorno do adquirente vem em `lr` (tabela de LRs: `"51"`
      é saldo insuficiente, `"54"` cartão vencido) e a mensagem do adquirente
      em `messages`. `Iugu.Charge.lr_category/1` diz se vale tentar
      de novo com o mesmo cartão.
  """

  @type kind ::
          :unauthorized
          | :forbidden
          | :not_found
          | :rate_limited
          | :validation
          | :declined
          | :server
          | :transport
          | :unexpected

  @type t :: %__MODULE__{
          kind: kind(),
          status: non_neg_integer() | nil,
          messages: [String.t()],
          fields: %{optional(String.t()) => [String.t()]},
          path: String.t() | nil,
          body: term(),
          reason: term(),
          lr: String.t() | nil
        }

  defexception [:kind, :status, :path, :body, :reason, :lr, messages: [], fields: %{}]

  @doc "Monta o erro a partir de uma resposta HTTP fora da faixa 2xx."
  @spec from_response(Req.Response.t(), String.t()) :: t()
  def from_response(%Req.Response{status: status, body: body}, path) do
    body = decode_body(body)

    %__MODULE__{
      kind: kind_for_status(status),
      status: status,
      path: path,
      body: body,
      messages: extract_messages(body),
      fields: extract_fields(body)
    }
  end

  @doc """
  Monta um erro nosso, sem ida à Iugu.

  Serve para a checagem que dá para fazer antes de gastar a chamada, como
  recusar um nome de subconta com dígito (a Iugu aceita e o Pix da subconta
  falha depois no Banco Central). O `status` fica `nil` justamente para
  separar isso de um 400 que veio de lá.
  """
  @spec validation(String.t(), String.t() | nil) :: t()
  def validation(message, path \\ nil) do
    %__MODULE__{kind: :validation, path: path, messages: [message]}
  end

  @doc """
  Monta a recusa de um cartão a partir do corpo que a Iugu devolveu.

  `status` é o HTTP real (200 na cobrança direta, 422 no Zero Auth), para
  que o log mostre que a Iugu respondeu e foi o emissor quem negou. `lr` é
  o código do adquirente como string (`"51"`), ou `nil` quando a resposta
  não trouxe um.
  """
  @spec declined(term(), String.t(), keyword()) :: t()
  def declined(body, path, opts \\ []) do
    lr = Keyword.get(opts, :lr)
    message = Keyword.get(opts, :message)

    %__MODULE__{
      kind: :declined,
      status: Keyword.get(opts, :status, 200),
      path: path,
      body: body,
      lr: normalize_lr(lr),
      messages: List.wrap(message)
    }
  end

  @doc "Monta o erro a partir de uma falha de transporte (timeout, DNS, TLS)."
  @spec from_exception(Exception.t(), String.t()) :: t()
  def from_exception(exception, path) do
    %__MODULE__{
      kind: :transport,
      path: path,
      reason: exception,
      messages: [Exception.message(exception)]
    }
  end

  @doc """
  Se vale a pena repetir a chamada.

  Vale só para requisição idempotente. A maioria das rotas de escrita da Iugu
  não aceita `Idempotency-Key` (saque, criação de subconta, configuração de
  conta), então um POST que estourou o timeout pode ter chegado lá, e repetir
  gera uma segunda movimentação.
  """
  @spec retriable?(t()) :: boolean()
  def retriable?(%__MODULE__{kind: kind}), do: kind in [:rate_limited, :server, :transport]

  @impl true
  def message(%__MODULE__{} = error) do
    detail =
      case error.messages do
        [] -> "sem mensagem"
        messages -> Enum.join(messages, "; ")
      end

    "Iugu #{error.kind}#{status_suffix(error)} em #{error.path || "?"}: #{detail}#{lr_suffix(error)}"
  end

  defp status_suffix(%__MODULE__{status: nil}), do: ""
  defp status_suffix(%__MODULE__{status: status}), do: " (HTTP #{status})"

  defp lr_suffix(%__MODULE__{lr: nil}), do: ""
  defp lr_suffix(%__MODULE__{lr: lr}), do: " (LR #{lr})"

  # O LR é uma string na resposta da cobrança e na documentação, mas nada
  # impede um inteiro de aparecer; o log e as buscas na tabela querem texto.
  defp normalize_lr(nil), do: nil
  defp normalize_lr(lr) when is_binary(lr), do: lr
  defp normalize_lr(lr) when is_integer(lr), do: Integer.to_string(lr)
  defp normalize_lr(lr), do: inspect(lr)

  # Alguns corpos de 422 são declarados text/plain mesmo com o payload sendo
  # JSON, e o Req só decodifica o que se declara JSON.
  defp decode_body(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{} = decoded} -> decoded
      _other -> body
    end
  end

  defp decode_body(body), do: body

  defp kind_for_status(401), do: :unauthorized
  defp kind_for_status(403), do: :forbidden
  defp kind_for_status(404), do: :not_found
  defp kind_for_status(429), do: :rate_limited
  defp kind_for_status(status) when status in 400..499, do: :validation
  defp kind_for_status(status) when status in 500..599, do: :server
  defp kind_for_status(_status), do: :unexpected

  defp extract_messages(%{"errors" => errors}) when is_binary(errors) and errors != "",
    do: [errors]

  defp extract_messages(%{"errors" => errors}) when is_list(errors) do
    Enum.map(errors, &stringify/1)
  end

  defp extract_messages(%{"errors" => %{} = errors}), do: field_messages(errors)

  defp extract_messages(%{"message" => %{} = errors}), do: field_messages(errors)

  defp extract_messages(%{"message" => message}) when is_binary(message) and message != "",
    do: [message]

  defp extract_messages(body) when is_binary(body) and body != "", do: [body]
  defp extract_messages(_body), do: []

  defp extract_fields(%{"errors" => %{} = errors}), do: extract_fields_from_map(errors)
  defp extract_fields(%{"message" => %{} = errors}), do: extract_fields_from_map(errors)
  defp extract_fields(_body), do: %{}

  # Ordenado para a linha de log ser estável entre execuções: mapas do Elixir
  # acima de 32 chaves iteram numa ordem que nada tem a ver com o JSON.
  defp field_messages(errors) do
    errors
    |> extract_fields_from_map()
    |> Enum.sort()
    |> Enum.flat_map(fn {field, messages} -> Enum.map(messages, &"#{field}: #{&1}") end)
  end

  defp extract_fields_from_map(errors) do
    Map.new(errors, fn {field, messages} ->
      {field, messages |> List.wrap() |> Enum.map(&stringify/1)}
    end)
  end

  defp stringify(value) when is_binary(value), do: value
  defp stringify(value), do: inspect(value)
end
