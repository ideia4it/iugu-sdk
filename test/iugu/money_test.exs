defmodule Iugu.MoneyTest do
  use ExUnit.Case, async: true

  doctest Iugu.Money

  alias Iugu.Money

  test "turns a price in reais into the integer of cents Iugu charges and reads it back" do
    # This is the ambiguity the module exists to remove: reais_to_cents(10)
    # must be R$ 10,00 and never 10 cents.
    assert Money.reais_to_cents(10) == 1_000
    assert Money.reais_to_cents(0) == 0

    # Iugu takes no fractional cent, so the third decimal rounds half up.
    assert Money.reais_to_cents(Decimal.new("0.155")) == 16
    assert Money.reais_to_cents(Decimal.new("0.154")) == 15

    # A refund line carries a negative value.
    assert Money.reais_to_cents(Decimal.new("-10.50")) == -1_050
    assert Money.reais_to_cents(-10) == -1_000

    # Nothing goes through float, so a long decimal stays exact.
    assert Money.reais_to_cents(Decimal.new("1234567.89")) == 123_456_789

    assert Decimal.equal?(Money.cents_to_reais(1_000), Decimal.new("10.00"))
    assert Decimal.equal?(Money.cents_to_reais(1), Decimal.new("0.01"))
    assert Decimal.equal?(Money.cents_to_reais(-1_050), Decimal.new("-10.50"))

    assert Money.reais_to_cents(Money.cents_to_reais(12_345)) == 12_345
  end

  test "reads the balance strings of the account endpoint in every documented form and refuses what it cannot read" do
    # The documented examples, including the sign after the currency and the
    # missing space of subaccounts_negative_balance_total.
    assert Money.parse_brl("R$ 58,03") == {:ok, 5_803}
    assert Money.parse_brl("R$ 0,00") == {:ok, 0}
    assert Money.parse_brl("R$ -2,47") == {:ok, -247}
    assert Money.parse_brl("R$100,00") == {:ok, 10_000}
    assert Money.parse_brl("-R$ 0,10") == {:ok, -10}

    # Thousands separators and surrounding whitespace.
    assert Money.parse_brl("R$ 1.234,56") == {:ok, 123_456}
    assert Money.parse_brl("R$ 1.234.567,89") == {:ok, 123_456_789}
    assert Money.parse_brl("  R$ 5,00\n") == {:ok, 500}

    # Anything else is an error rather than a silent zero: the statement's
    # "100.0" and "19.40 BRL" belong to other parsers, and a number is not a
    # formatted string.
    for unreadable <- ["100.00", "19.40 BRL", "R$ 1,5", "R$ 1.23,45", "R$", "", "abc", 100, nil] do
      assert Money.parse_brl(unreadable) == :error, "esperava :error para #{inspect(unreadable)}"
    end

    assert Money.parse_brl("R$ 123,45") == {:ok, Money.reais_to_cents(Decimal.new("123.45"))}
  end
end
