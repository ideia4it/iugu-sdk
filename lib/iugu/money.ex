defmodule Iugu.Money do
  @moduledoc """
  Fronteira de dinheiro entre a aplicação e a Iugu.

  Nas requisições a Iugu recebe centavos inteiros (`price_cents`,
  `amount_cents`, `value_cents`, `cents` nos splits), com uma exceção: o
  pedido de saque (`request_withdraw`) recebe `amount` como decimal em reais.

  Nas respostas ela é menos uniforme. Os saldos de `GET /v1/accounts/{id}`
  (`balance`, `balance_available_for_withdraw`, `payable_balance`) só vêm
  como string formatada em pt-BR, `"R$ 58,03"`, com o sinal depois da moeda
  (`"R$ -2,47"`) e às vezes sem espaço (`"R$100,00"`). `parse_brl/1` traz
  essas strings de volta para centavos inteiros sem passar por float.

  Os extratos e a conciliação de saques usam uma terceira forma: decimal em
  reais sem símbolo, com ponto ou vírgula e às vezes o sufixo `BRL`
  (`"4500.0"`, `"19.40 BRL"`, `"0,02 BRL"`, `"2.59"`). `parse_reais/1` cobre
  essa. As duas funções são separadas de propósito: `"100.0"` é R$ 100,00
  num campo `amount` e 100 centavos num campo `amount_cents`, e só o nome do
  campo diz qual leitura vale.

  Os nomes das funções dizem a unidade dos dois lados de propósito: `to_cents`
  sozinho não distingue "reais para centavos" de "já está em centavos", e essa
  ambiguidade é exatamente o bug que se paga caro.
  """

  @brl_pattern ~r/\A\s*(?<sign_before>-)?\s*R\$\s*(?<sign_after>-)?\s*(?<integer>\d{1,3}(?:\.\d{3})*|\d+),(?<fraction>\d{2})\s*\z/
  @reais_pattern ~r/\A\s*(?<sign>-)?(?<integer>\d+)(?:[.,](?<fraction>\d{1,2}))?(?:\s*BRL)?\s*\z/

  @doc """
  Converte reais em centavos inteiros.

      iex> Iugu.Money.reais_to_cents(Decimal.new("10.00"))
      1000

      iex> Iugu.Money.reais_to_cents(Decimal.new("0.155"))
      16

  Inteiro é lido como reais inteiros, e não como centavos já convertidos:

      iex> Iugu.Money.reais_to_cents(10)
      1000
  """
  @spec reais_to_cents(Decimal.t() | integer()) :: integer()
  def reais_to_cents(%Decimal{} = reais) do
    reais
    |> Decimal.mult(100)
    |> Decimal.round(0, :half_up)
    |> Decimal.to_integer()
  end

  def reais_to_cents(reais) when is_integer(reais), do: reais * 100

  @doc """
  Converte centavos inteiros em reais.

      iex> Iugu.Money.cents_to_reais(1000)
      Decimal.new("10.00")
  """
  @spec cents_to_reais(integer()) :: Decimal.t()
  def cents_to_reais(cents) when is_integer(cents) do
    cents
    |> Decimal.new()
    |> Decimal.div(100)
    |> Decimal.round(2)
  end

  @doc """
  Lê a string de dinheiro formatada que a Iugu devolve nos saldos e devolve
  centavos inteiros.

      iex> Iugu.Money.parse_brl("R$ 1.234,56")
      {:ok, 123456}

      iex> Iugu.Money.parse_brl("R$ -2,47")
      {:ok, -247}

      iex> Iugu.Money.parse_brl("-R$ 0,10")
      {:ok, -10}

      iex> Iugu.Money.parse_brl("R$100,00")
      {:ok, 10000}

  Qualquer outra forma, inclusive número cru ou `nil`, é `:error`, para que
  um saldo ilegível nunca vire zero em silêncio:

      iex> Iugu.Money.parse_brl("100.00")
      :error

      iex> Iugu.Money.parse_brl(nil)
      :error

  O separador de milhar como ponto segue a convenção pt-BR; nenhum exemplo da
  documentação passa de R$ 1.000,00, então **confirme contra a conta** o
  primeiro saldo dessa ordem.
  """
  @spec parse_brl(term()) :: {:ok, integer()} | :error
  def parse_brl(value) when is_binary(value) do
    case Regex.named_captures(@brl_pattern, value) do
      %{"sign_before" => sign_before, "sign_after" => sign_after} = captures ->
        integer = captures["integer"] |> String.replace(".", "") |> String.to_integer()
        cents = integer * 100 + String.to_integer(captures["fraction"])

        {:ok, apply_sign(cents, sign_before <> sign_after)}

      nil ->
        :error
    end
  end

  def parse_brl(_value), do: :error

  @doc """
  Lê o decimal em reais sem símbolo dos extratos e da conciliação de saques e
  devolve centavos inteiros.

      iex> Iugu.Money.parse_reais("4500.0")
      {:ok, 450000}

      iex> Iugu.Money.parse_reais("19.40 BRL")
      {:ok, 1940}

      iex> Iugu.Money.parse_reais("0,02 BRL")
      {:ok, 2}

      iex> Iugu.Money.parse_reais("-1.0")
      {:ok, -100}

  Mais de duas casas decimais não é dinheiro nesta API (`"-0.0474"` é uma
  taxa), e número cru ou `nil` também são `:error`, para que um valor
  ilegível nunca vire zero em silêncio:

      iex> Iugu.Money.parse_reais("-0.0474")
      :error

      iex> Iugu.Money.parse_reais(nil)
      :error
  """
  @spec parse_reais(term()) :: {:ok, integer()} | :error
  def parse_reais(value) when is_binary(value) do
    case Regex.named_captures(@reais_pattern, value) do
      %{"sign" => sign, "integer" => integer, "fraction" => fraction} ->
        cents =
          String.to_integer(integer) * 100 +
            (fraction |> String.pad_trailing(2, "0") |> String.to_integer())

        {:ok, apply_sign(cents, sign)}

      nil ->
        :error
    end
  end

  def parse_reais(_value), do: :error

  defp apply_sign(cents, ""), do: cents
  defp apply_sign(cents, _minus), do: -cents
end
