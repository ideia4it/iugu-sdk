defmodule Iugu.Deposit do
  @moduledoc """
  Depósito: dinheiro que entrou na conta Iugu por Pix, QR Code estático ou
  TED, sem fatura no meio.

  É a entrada da "conta digital" do BaaS. Uma cobrança paga é fatura
  (`Iugu.Invoice`); um depósito é alguém mandando dinheiro para a
  chave Pix ou para os dados bancários da conta (`Iugu.PixKey`), ou
  pagando um QR Code de `Iugu.StaticQrCode`. `deposit_type` diz
  qual: `pix`, `qrcode` ou `ted`.

  ## Ciclo de vida

  Os webhooks `deposit.pix_status_changed` e `deposit.ted_status_changed`
  disparam "sempre que o status de um depósito é alterado", e são o jeito de
  saber que o dinheiro entrou; não há rota para esperar um depósito. Os
  status documentados: `accepted` (caiu), `rejected` (`rejected_at`),
  `processing_refund` (depois de `refund/2`) e `refunded`, este acrescentado
  em 2026-08-11 ao webhook de Pix para "depósitos que foram devolvidos ao
  pagador". Se um depósito nasce num estado anterior a `accepted` **não está
  documentado**.

  ## Devolver um Pix

  `refund/2` devolve um depósito Pix inteiro ao pagador (`PUT
  /v1/deposits/{id}/refund`, sem corpo). Só vale para Pix: TED não tem
  devolução por aqui, e a Iugu responde 400 `Não é possivel reembolsar este
  depósito.` para o que não pode (já devolvido, TED, fora do prazo que ela
  não documenta). A resposta vem com `status: "processing_refund"`; o
  `refunded` chega pelo webhook.

  ## Qual token

  `live_api_token` ou `test_api_token` da conta que recebeu, em `api_token:`.
  Nenhuma rota exige assinatura RSA. Se a mestre enxerga os depósitos das
  subcontas **não está documentado**; o `account_id` em cada item sugere que
  sim.

  ## O que não está confirmado

    * id desconhecido em `get/2` é **400** `{"errors": "Deposit Not Found"}`
      na referência, não 404; `not_found?/1` reconhece as duas formas
    * se `GET /v1/deposits` traz `totalItems` (o exemplo só mostra `items`) e
      filtros além de `start` e `limit` (nenhum documentado)
    * o prazo para devolver um Pix e se `refund/2` aceita valor parcial (a
      rota não tem corpo)
    * `amount` vem em duas grafias nos exemplos (`R$50,00` e `R$549.20`); o
      SDK lê `amount_cents`, que é inteiro nas duas
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Pagination
  alias Iugu.Response

  @path "/v1/deposits"
  @max_limit 1_000
  @statuses ["accepted", "rejected", "processing_refund", "refunded"]
  @deposit_types ["pix", "qrcode", "ted"]

  @type party :: %{
          name: String.t() | nil,
          document_number: String.t() | nil,
          document_type: String.t() | nil,
          bank: String.t() | nil,
          branch: String.t() | nil,
          account_number: String.t() | nil,
          account_digit: String.t() | nil
        }

  @type t :: %{
          id: String.t() | nil,
          status: String.t() | nil,
          deposit_type: String.t() | nil,
          amount_cents: integer() | nil,
          account_id: String.t() | nil,
          receipt_url: String.t() | nil,
          sender: party(),
          receiver: party(),
          accepted_at: String.t() | nil,
          transfered_at: String.t() | nil,
          rejected_at: String.t() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          body: map()
        }

  @type page :: %{deposits: [t()], page_info: Pagination.page_info()}

  @doc """
  Um depósito pelo id devolvido no `deposit_id` do webhook, com o
  comprovante em `receipt_url`.

  Token da conta que recebeu, sem assinatura. Id desconhecido volta como
  `{:error, _}` que `not_found?/1` reconhece.
  """
  @spec get(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def get(deposit_id, opts \\ []) when is_binary(deposit_id) do
    with {:ok, body} <- Client.get(item_path(deposit_id), opts) do
      {:ok, normalize(body)}
    end
  end

  @doc """
  Depósitos da conta que autentica, paginados.

  `GET /v1/deposits`, token da conta. Só `:start` e `:limit` (padrão 100,
  máximo 1.000, o maior da API); não há filtro por status, tipo ou data.
  """
  @spec list(keyword()) :: {:ok, page()} | {:error, Error.t()}
  def list(opts \\ []) do
    {page_opts, req_opts} = Keyword.split(opts, [:start, :limit])
    params = Pagination.params(page_opts, @max_limit)

    with {:ok, body} <- Client.get(@path, Keyword.put(req_opts, :params, params)) do
      {:ok,
       %{
         deposits: body |> Response.items() |> Enum.map(&normalize/1),
         page_info:
           Pagination.page_info(body,
             start: Map.get(params, :start, 0),
             limit: Map.get(params, :limit)
           )
       }}
    end
  end

  @doc """
  Percorre todas as páginas de `list/1`.

  Para na primeira página menor que `limit` e levanta o
  `Iugu.Error` da primeira página que falhar.
  """
  @spec stream(keyword()) :: Enumerable.t()
  def stream(opts \\ []) do
    {page_opts, other_opts} = Keyword.split(opts, [:start, :limit])

    Pagination.stream(
      fn stream_page_opts ->
        with {:ok, page} <- list(Keyword.merge(other_opts, stream_page_opts)) do
          {:ok, page.deposits}
        end
      end,
      ["items"],
      Keyword.put(page_opts, :max_limit, @max_limit)
    )
  end

  @doc """
  Devolve um depósito Pix inteiro ao pagador. Veja o moduledoc.

  `PUT /v1/deposits/{id}/refund`, token da conta que recebeu, sem corpo e
  sem assinatura declarada. Sem retry: a repetição de uma devolução que
  entrou responde 400, mas uma que ficou em timeout não deve sair duas
  vezes. A resposta vem normalizada, com `status: "processing_refund"`.
  """
  @spec refund(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def refund(deposit_id, opts \\ []) when is_binary(deposit_id) do
    with {:ok, body} <- Client.request(:put, "#{item_path(deposit_id)}/refund", opts) do
      {:ok, normalize(body)}
    end
  end

  @doc """
  Se o erro de `get/2` é "depósito não existe".

  A referência documenta a falha como 400 com `Deposit Not Found` no corpo;
  um 404 também conta, para o dia em que a Iugu corrigir o status.
  """
  @spec not_found?(Error.t()) :: boolean()
  def not_found?(%Error{kind: :not_found}), do: true

  def not_found?(%Error{kind: :validation, status: 400, messages: messages}) do
    Enum.any?(messages, &String.ends_with?(&1, "Not Found"))
  end

  def not_found?(%Error{}), do: false

  @doc "Os status de depósito documentados, reunindo referência e webhooks."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Os valores documentados de `deposit_type`."
  @spec deposit_types() :: [String.t()]
  def deposit_types, do: @deposit_types

  defp normalize(body) when is_map(body) do
    %{
      id: Response.get_any(body, ["id", "deposit_id"]),
      status: Map.get(body, "status"),
      deposit_type: Map.get(body, "deposit_type"),
      amount_cents: Response.integer(body, ["amount_cents"]),
      account_id: Map.get(body, "account_id"),
      receipt_url: Map.get(body, "receipt_url"),
      sender: party(body, "sender"),
      receiver: party(body, "receiver"),
      accepted_at: Map.get(body, "accepted_at"),
      transfered_at: Map.get(body, "transfered_at"),
      rejected_at: Map.get(body, "rejected_at"),
      created_at: Map.get(body, "created_at"),
      updated_at: Map.get(body, "updated_at"),
      body: body
    }
  end

  # A Iugu achata remetente e destinatário em chaves com prefixo
  # (`sender_account_bank`, `receiver_name`); o mapa normalizado reagrupa os
  # dois lados com os mesmos nomes.
  defp party(body, prefix) do
    %{
      name: Map.get(body, "#{prefix}_name"),
      document_number: Map.get(body, "#{prefix}_document_number"),
      document_type: Map.get(body, "#{prefix}_document_type"),
      bank: Map.get(body, "#{prefix}_account_bank"),
      branch: Map.get(body, "#{prefix}_account_branch"),
      account_number: Map.get(body, "#{prefix}_account_number"),
      account_digit: Map.get(body, "#{prefix}_account_digit")
    }
  end

  defp item_path(deposit_id), do: "#{@path}/#{Client.encode_path_segment(deposit_id)}"
end
