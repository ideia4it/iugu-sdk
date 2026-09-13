defmodule Iugu.PaginationTest do
  use ExUnit.Case, async: true

  alias Iugu.Error
  alias Iugu.Pagination

  doctest Iugu.Pagination

  test "sends only a limit the route accepts, the offset and the one documented sort, and reads the page back" do
    assert Pagination.params(start: 200, limit: 500) == %{start: 200, limit: 100}

    # Plans and marketplace take up to 1.000 per page.
    assert Pagination.params([limit: 500], 1_000) == %{limit: 500}
    assert Pagination.params([limit: 5_000], 1_000) == %{limit: 1_000}

    assert Pagination.params([]) == %{}
    assert Pagination.params(limit: 0) == %{}
    assert Pagination.params(limit: -1) == %{}
    assert Pagination.params(limit: "10") == %{}

    # Transfer receipts are the only listing with a documented sort.
    assert Pagination.params(sort_by: "amount_cents") == %{sortby: "amount_cents"}

    # Iugu echoes neither start nor limit, so they come from what was sent;
    # totalItems is reported but never trusted to end a loop.
    assert Pagination.page_info(%{"items" => [], "totalItems" => 66}, start: 100, limit: 50) ==
             %{start: 100, limit: 50, total_items: 66}

    assert Pagination.page_info(%{"items" => []}) == %{start: 0, limit: nil, total_items: nil}
    assert Pagination.page_info([]) == %{start: 0, limit: nil, total_items: nil}
  end

  test "walks the pages until one comes back short, ignores totalItems and raises when a page fails" do
    # totalItems says 2 next to more items than that, as the docs' own sample
    # does: the walk still reaches the third item.
    pages = %{
      0 => page(["a", "b"], 2),
      2 => page(["c"], 2)
    }

    {items, seen} = collect(pages, limit: 2)

    assert items == ["a", "b", "c"]
    assert seen == [[start: 0, limit: 2], [start: 2, limit: 2]]

    # A full last page costs one extra request that comes back empty.
    {items, seen} = collect(%{0 => page(["a", "b"], 2), 2 => page([], 2)}, limit: 2)

    assert items == ["a", "b"]
    assert length(seen) == 2

    {_items, seen} = collect(%{10 => page(["a"], 1)}, start: 10, limit: 2)

    assert seen == [[start: 10, limit: 2]]

    # Without a usable limit the page size is the route maximum, 100 by
    # default and whatever the caller says for the routes that take 1.000.
    for options <- [[limit: 5_000], []] do
      {_items, seen} = collect(%{0 => page(["a"], 1)}, options)

      assert seen == [[start: 0, limit: 100]]
    end

    {_items, seen} = collect(%{0 => page(["a"], 1)}, max_limit: 1_000)

    assert seen == [[start: 0, limit: 1_000]]

    # And a failed page raises instead of becoming a silently short list.
    failing = fn _opts -> {:error, %Error{kind: :unauthorized, path: "/v1/invoices"}} end

    assert_raise Error, fn ->
      failing |> Pagination.stream(["items"]) |> Enum.to_list()
    end
  end

  defp page(items, total_items) do
    %{"items" => items, "totalItems" => total_items}
  end

  defp collect(pages, opts) do
    test_pid = self()

    fetch_fun = fn page_opts ->
      send(test_pid, {:fetched, page_opts})

      {:ok, Map.fetch!(pages, Keyword.fetch!(page_opts, :start))}
    end

    items = fetch_fun |> Pagination.stream(["items"], opts) |> Enum.to_list()

    {items, drain()}
  end

  defp drain(acc \\ []) do
    receive do
      {:fetched, page_opts} -> drain(acc ++ [page_opts])
    after
      0 -> acc
    end
  end
end
