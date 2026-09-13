defmodule Iugu.Pagination do
  @moduledoc """
  Paginação offset das listagens da Iugu.

  É `start` + `limit`, não cursor: `start` diz quantos registros pular e
  `limit` quantos devolver, e "esses parâmetros funcionam mesmo que não sejam
  chamados simultaneamente". A página N começa em `start = N * limit`.

  O máximo de `limit` muda por rota: 100 em faturas, clientes, assinaturas e
  transferências (que também é o padrão), 1.000 em planos, marketplace e
  extrato financeiro. `params/2` prende o valor ao máximo que o chamador
  informa, com 100 como padrão.

  Três armadilhas:

    * `totalItems` **não serve para encerrar o loop**. Em faturas ele é o
      total da conta ignorando os filtros; em clientes e assinaturas passou a
      ser o tamanho da página; em planos só aparece com `query`. A própria
      página de paginação da documentação mostra `"totalItems": 2` ao lado de
      dez itens. `stream/3` para quando a página volta menor que `limit`.
    * clientes e assinaturas bloqueiam paginação profunda: `start > 100` sem
      um filtro identificador (`updated_since`, `created_at_from`) responde
      400. `stream/3` não contorna isso; o chamador passa o filtro.
    * assinaturas recusam offset acima de 10.000 ("Limite para listagem
      excedido (max. 10000)").

  Nenhuma listagem documenta ordenação, exceto a de comprovantes de
  transferência para terceiros, que aceita `sortby` com `amount_cents` ou
  `executed_at`. As demais vêm "ordenadas pela data de criação, da mais à
  menos recente". Um `sort_by` fora dessa rota **não está documentado**;
  confirme contra a conta antes de depender dele.
  """

  alias Iugu.Params
  alias Iugu.Response

  @default_max_limit 100

  @type page_info :: %{
          start: non_neg_integer(),
          limit: non_neg_integer() | nil,
          total_items: non_neg_integer() | nil
        }

  @doc """
  Monta os parâmetros de query, com `limit` preso ao máximo da rota.

      iex> Iugu.Pagination.params(start: 200, limit: 500)
      %{start: 200, limit: 100}

      iex> Iugu.Pagination.params([limit: 500], 1_000)
      %{limit: 500}

      iex> Iugu.Pagination.params(sort_by: "executed_at")
      %{sortby: "executed_at"}
  """
  @spec params(keyword(), pos_integer()) :: map()
  def params(opts \\ [], max_limit \\ @default_max_limit) do
    %{}
    |> Params.put_present(:start, Keyword.get(opts, :start))
    |> Params.put_present(:limit, clamp_limit(Keyword.get(opts, :limit), max_limit))
    |> Params.put_present(:sortby, Keyword.get(opts, :sort_by))
  end

  @doc """
  Resume a página que voltou.

  A Iugu não ecoa `start` nem `limit` na resposta, então eles vêm das opções
  que o chamador enviou, e `total_items` de `totalItems` (veja o moduledoc
  sobre o quanto confiar nele).
  """
  @spec page_info(map() | list(), keyword()) :: page_info()
  def page_info(body, opts \\ []) do
    %{
      start: Keyword.get(opts, :start, 0),
      limit: Keyword.get(opts, :limit),
      total_items: Response.total_items(body)
    }
  end

  @doc """
  Percorre todas as páginas de uma listagem.

  `fetch_fun` recebe as opções de paginação (`start` e `limit`) e devolve o
  mesmo `{:ok, body} | {:error, Iugu.Error.t()}` das funções do SDK.
  `collection_keys` diz onde estão os itens no corpo (`["items"]` na maioria
  das rotas). Opções: `:start` inicial, `:limit` por página e `:max_limit` da
  rota (padrão 100).

  O stream para na primeira página menor que `limit`, e levanta o erro da
  primeira página que falhar para que a falha não vire uma lista curta
  silenciosa.
  """
  @spec stream((keyword() -> {:ok, map()} | {:error, Exception.t()}), [String.t()], keyword()) ::
          Enumerable.t()
  def stream(fetch_fun, collection_keys \\ ["items"], opts \\ []) do
    max_limit = Keyword.get(opts, :max_limit, @default_max_limit)
    limit = clamp_limit(Keyword.get(opts, :limit), max_limit) || max_limit

    Stream.resource(
      fn -> {Keyword.get(opts, :start, 0), false} end,
      &next_page(&1, fetch_fun, collection_keys, limit),
      fn _state -> :ok end
    )
  end

  defp next_page({_start, true}, _fetch_fun, _collection_keys, _limit), do: {:halt, :done}

  defp next_page({start, false}, fetch_fun, collection_keys, limit) do
    case fetch_fun.(start: start, limit: limit) do
      {:ok, body} ->
        items = Response.items(body, collection_keys)

        {items, {start + limit, length(items) < limit}}

      {:error, error} ->
        raise error
    end
  end

  defp clamp_limit(nil, _max_limit), do: nil
  defp clamp_limit(limit, max_limit) when is_integer(limit) and limit > max_limit, do: max_limit
  defp clamp_limit(limit, _max_limit) when is_integer(limit) and limit > 0, do: limit
  defp clamp_limit(_limit, _max_limit), do: nil
end
