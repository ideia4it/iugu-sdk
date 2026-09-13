defmodule Iugu.StaticQrCode do
  @moduledoc """
  QR Code estático: um Pix copia-e-cola permanente da conta Iugu, com ou sem
  valor, que vira um depósito a cada pagamento.

  É o "receba por Pix sem emitir fatura" do BaaS. Uma fatura
  (`Iugu.Invoice`) gera um QR dinâmico, de uso único e com
  vencimento; o estático não expira, pode ser pago quantas vezes quiserem e
  cada pagamento chega como `Iugu.Deposit` com `deposit_type:
  "qrcode"` e o `qr_code_id` no webhook `deposit.pix_status_changed`. Serve
  para a plaquinha no balcão da loja.

  ## Com ou sem valor

  Sem `amount_cents` "é criado um QR Code que o cliente final pode escolher"
  o valor na hora de pagar. `description` é opcional e tem no máximo 25
  caracteres (a Iugu responde 422 `é muito longo (máximo: 25 caracteres)`;
  `create/2` confere antes). O QR é sempre da chave Pix da própria conta
  (`pix_key` na resposta), então a conta precisa ter uma chave ativa
  (`Iugu.PixKey`).

  ## Qual token

  `live_api_token` da conta dona do QR em `api_token:`; em teste a chave Pix
  não existe, e se a rota responde algo útil com `test_api_token` **não
  está documentado**. Nenhuma rota exige assinatura RSA, e não há rota para
  apagar um QR.

  ## O que não está confirmado

    * se `amount_cents` vai como inteiro ou string (a referência declara
      string e exemplifica inteiro; o SDK manda inteiro)
    * valor mínimo, forma do 404 em `get/2` e o máximo de `limit` em
      `list/1` (o SDK prende a 100)
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Pagination
  alias Iugu.Params
  alias Iugu.Response

  @path "/v1/static_qr_codes"
  @max_limit 100
  @max_description_length 25
  @create_fields [:amount_cents, :description]

  @type t :: %{
          id: String.t() | nil,
          payload: String.t() | nil,
          pix_key: String.t() | nil,
          amount_cents: integer() | nil,
          url: String.t() | nil,
          description: String.t() | nil,
          body: map()
        }

  @type page :: %{static_qr_codes: [t()], page_info: Pagination.page_info()}

  @doc """
  Cria um QR Code estático. Veja o moduledoc.

  `POST /v1/static_qr_codes`, token da conta, sem assinatura e sem retry (um
  timeout pode ter criado o QR, e não há rota para apagar o duplicado).
  `attrs` leva `amount_cents` (inteiro positivo, opcional) e `description`
  (até 25 caracteres, opcional), em átomo ou string; uma chave fora dessas
  levanta `ArgumentError`. A resposta vem normalizada: `payload` é o
  copia-e-cola, `url` a imagem em `faturas.iugu.com`.
  """
  @spec create(map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(attrs, opts \\ []) when is_map(attrs) do
    body = build_create_body(attrs)

    with :ok <- validate_amount(Map.get(body, "amount_cents")),
         :ok <-
           Params.validate_length(
             Map.get(body, "description"),
             @max_description_length,
             "description",
             @path
           ),
         {:ok, response} <- Client.post(@path, body, opts) do
      {:ok, normalize(response)}
    end
  end

  @doc "Um QR Code estático pelo `qr_code_id`. Token da conta, sem assinatura."
  @spec get(String.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def get(qr_code_id, opts \\ []) when is_binary(qr_code_id) do
    with {:ok, body} <- Client.get(item_path(qr_code_id), opts) do
      {:ok, normalize(body)}
    end
  end

  @doc """
  QR Codes estáticos da conta que autentica, paginados.

  `GET /v1/static_qr_codes`, token da conta. Só `:start` e `:limit` (preso a
  100); não há filtro.
  """
  @spec list(keyword()) :: {:ok, page()} | {:error, Error.t()}
  def list(opts \\ []) do
    {page_opts, req_opts} = Keyword.split(opts, [:start, :limit])
    params = Pagination.params(page_opts, @max_limit)

    with {:ok, body} <- Client.get(@path, Keyword.put(req_opts, :params, params)) do
      {:ok,
       %{
         static_qr_codes: body |> Response.items() |> Enum.map(&normalize/1),
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
          {:ok, page.static_qr_codes}
        end
      end,
      ["items"],
      Keyword.put(page_opts, :max_limit, @max_limit)
    )
  end

  defp normalize(body) when is_map(body) do
    %{
      id: Map.get(body, "qr_code_id"),
      payload: Map.get(body, "qr_code_payload"),
      pix_key: Map.get(body, "qr_code_pix_key"),
      amount_cents: Response.integer(body, ["qr_code_amount_cents"]),
      url: Map.get(body, "qr_code"),
      description: Map.get(body, "qr_code_description"),
      body: body
    }
  end

  defp build_create_body(attrs) do
    Map.new(attrs, fn {key, value} ->
      {key |> Params.field!(@create_fields, "QR Code estático") |> Atom.to_string(), value}
    end)
  end

  defp validate_amount(nil), do: :ok
  defp validate_amount(amount_cents) when is_integer(amount_cents) and amount_cents > 0, do: :ok

  defp validate_amount(_amount_cents) do
    {:error,
     Error.validation("amount_cents deve ser um inteiro positivo em centavos, ou ausente.", @path)}
  end

  defp item_path(qr_code_id), do: "#{@path}/#{Client.encode_path_segment(qr_code_id)}"
end
