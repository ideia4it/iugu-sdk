defmodule Iugu.Response do
  @moduledoc """
  Leitura tolerante do corpo devolvido pela Iugu.

  A API é inconsistente de um endpoint para o outro, e isso está documentado:

    * as listagens vêm em `{"items": [...], "totalItems": n}`, mas a de
      transferências vem em `{"sent": [...], "received": [...]}`, a de formas
      de pagamento é um array cru e a conciliação de saques escreve
      `total_items` em snake_case
    * os booleanos que são perguntas mantêm a interrogação na chave:
      `"is_verified?"`, `"can_receive?"`, `"has_bank_address?"`
    * o mesmo split traz o id em `"id"` numa página e em `"d"` em outra
    * números viram string conforme a rota (`"max_installments": "12"`,
      `"amount_cents": "161.0"`)

  Um decodificador estrito passa na suíte e quebra em produção. Estas funções
  aceitam as formas conhecidas e devolvem o que o chamador consegue usar.
  """

  @doc """
  Primeira chave presente entre `keys`.

      iex> Iugu.Response.fetch_any(%{"d" => 1}, ["id", "d"])
      {:ok, 1}

      iex> Iugu.Response.fetch_any(%{}, ["id"])
      :error
  """
  @spec fetch_any(map(), [String.t()]) :: {:ok, term()} | :error
  def fetch_any(body, keys) when is_map(body) do
    Enum.reduce_while(keys, :error, fn key, acc ->
      case Map.fetch(body, key) do
        {:ok, value} -> {:halt, {:ok, value}}
        :error -> {:cont, acc}
      end
    end)
  end

  def fetch_any(_body, _keys), do: :error

  @doc "Como `fetch_any/2`, com valor padrão."
  @spec get_any(map(), [String.t()], term()) :: term()
  def get_any(body, keys, default \\ nil) do
    case fetch_any(body, keys) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  Itens de uma listagem, sempre como lista.

  Aceita o envelope `{"items": [...]}`, o array cru das rotas que não paginam
  e qualquer outra chave que o chamador indique (`sent`, `received`).

      iex> Iugu.Response.items(%{"items" => [1, 2], "totalItems" => 2})
      [1, 2]

      iex> Iugu.Response.items([1, 2])
      [1, 2]

      iex> Iugu.Response.items(%{"sent" => [1]}, ["sent"])
      [1]

      iex> Iugu.Response.items(%{})
      []
  """
  @spec items(map() | list(), [String.t()]) :: [term()]
  def items(body, keys \\ ["items"])
  def items(body, _keys) when is_list(body), do: body

  def items(body, keys) do
    case fetch_any(body, keys) do
      {:ok, values} when is_list(values) -> values
      _other -> []
    end
  end

  @doc """
  Total declarado pela listagem, em `totalItems` ou `total_items`.

  O valor não é confiável para encerrar a paginação: em faturas ele é o total
  da conta ignorando os filtros, em clientes e assinaturas passou a ser o
  tamanho da página, e em planos só aparece quando há `query`. Serve para
  exibir, não para decidir.

      iex> Iugu.Response.total_items(%{"items" => [], "totalItems" => 66})
      66

      iex> Iugu.Response.total_items(%{"total_items" => 3})
      3

      iex> Iugu.Response.total_items(%{"items" => []})
      nil
  """
  @spec total_items(map() | list()) :: non_neg_integer() | nil
  def total_items(body) do
    case fetch_any(body, ["totalItems", "total_items"]) do
      {:ok, total} when is_integer(total) -> total
      _other -> nil
    end
  end

  @doc """
  Booleano cuja chave a Iugu escreve com interrogação no fim.

  Procura `name <> "?"` e depois `name` sem a interrogação, para o dia em que
  uma rota nova deixar a pergunta de lado.

      iex> Iugu.Response.flag(%{"is_verified?" => true}, "is_verified")
      true

      iex> Iugu.Response.flag(%{"is_verified" => true}, "is_verified")
      true

      iex> Iugu.Response.flag(%{}, "is_verified")
      false
  """
  @spec flag(map(), String.t(), boolean()) :: boolean()
  def flag(body, name, default \\ false) when is_binary(name) do
    case fetch_any(body, [name <> "?", name]) do
      {:ok, value} when is_boolean(value) -> value
      _other -> default
    end
  end

  @doc """
  Inteiro que a Iugu ora manda como número, ora como string.

      iex> Iugu.Response.integer(%{"max_installments" => "12"}, ["max_installments"])
      12

      iex> Iugu.Response.integer(%{"amount_cents" => "161.0"}, ["amount_cents"])
      161

      iex> Iugu.Response.integer(%{"customer_minimum_balance_cents" => 3000}, ["customer_minimum_balance_cents"])
      3000

      iex> Iugu.Response.integer(%{}, ["amount_cents"])
      nil
  """
  @spec integer(map(), [String.t()]) :: integer() | nil
  def integer(body, keys) do
    case fetch_any(body, keys) do
      {:ok, value} when is_integer(value) -> value
      {:ok, value} when is_binary(value) -> parse_integer(value)
      _other -> nil
    end
  end

  # "161.0" é como o extrato financeiro escreve centavos; o que vem depois do
  # ponto só é descartado quando é zero, senão o valor não é inteiro.
  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      {integer, fraction} -> if Regex.match?(~r/\A\.0+\z/, fraction), do: integer, else: nil
      :error -> nil
    end
  end
end
