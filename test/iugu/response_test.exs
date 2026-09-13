defmodule Iugu.ResponseTest do
  use ExUnit.Case, async: true

  alias Iugu.Response

  doctest Iugu.Response

  test "reads a listing, its total, a question mark boolean and a stringly integer whichever shape the API answered with" do
    # The usual envelope, the bare array of payment methods, the sent and
    # received keys of transfers, and a body with no items at all.
    assert Response.items(%{"items" => [%{"id" => "A"}], "totalItems" => 1}) == [%{"id" => "A"}]
    assert Response.items([%{"id" => "A"}]) == [%{"id" => "A"}]

    assert Response.items(%{"sent" => [%{"id" => "A"}], "received" => []}, ["sent"]) == [
             %{"id" => "A"}
           ]

    assert Response.items(%{"items" => "not a list"}) == []
    assert Response.items(%{}) == []
    assert Response.items(nil) == []

    # totalItems in camelCase almost everywhere, total_items on withdraw
    # conciliations, and neither on a bare array.
    assert Response.total_items(%{"items" => [], "totalItems" => 66}) == 66
    assert Response.total_items(%{"items" => [], "total_items" => 3}) == 3
    assert Response.total_items(%{"items" => [], "totalItems" => "66"}) == nil
    assert Response.total_items([]) == nil

    # The question mark stays in the key: is_verified?, can_receive?,
    # has_bank_address?.
    account = %{"is_verified?" => true, "can_receive?" => false, "marketplace" => true}

    assert Response.flag(account, "is_verified")
    refute Response.flag(account, "can_receive")
    assert Response.flag(account, "marketplace")
    refute Response.flag(account, "has_bank_address")
    assert Response.flag(account, "has_bank_address", true)
    refute Response.flag(%{"is_verified?" => "true"}, "is_verified")

    # Numbers that come back as strings: installments in configuration, cents
    # with a trailing .0 in the financial statement.
    configuration = %{"max_installments" => "12", "extra_due" => 2, "amount_cents" => "161.0"}

    assert Response.integer(configuration, ["max_installments"]) == 12
    assert Response.integer(configuration, ["extra_due"]) == 2
    assert Response.integer(configuration, ["amount_cents"]) == 161
    assert Response.integer(%{"amount_cents" => "161.5"}, ["amount_cents"]) == nil
    assert Response.integer(%{"amount_cents" => "abc"}, ["amount_cents"]) == nil
    assert Response.integer(%{"amount_cents" => 1.0}, ["amount_cents"]) == nil

    # The split id is "id" on one page and "d" on another.
    assert Response.get_any(%{"d" => "SPLIT"}, ["id", "d"]) == "SPLIT"
    assert Response.get_any(%{}, ["id", "d"], "none") == "none"
  end
end
