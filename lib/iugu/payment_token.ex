defmodule Iugu.PaymentToken do
  @moduledoc """
  Token de cartão de crédito: a representação de uso único que substitui os
  dados do cartão na cobrança direta e na forma de pagamento salva.

  ## Quem pode chamar esta rota

  `POST /v1/payment_token` recebe o número do cartão em claro, e por isso a
  documentação avisa: "Esta chamada API deve ser utilizada apenas em
  aplicações sem compatibilidade com JavaScript como por exemplo aplicações
  móveis. Se você efetuar esta chamada por dentro de seus servidores estará
  sujeito a uma auditoria do PCI." Para telas web o caminho é o iugu.js no
  navegador (`Iugu.setAccountID`, `Iugu.createPaymentToken`), que devolve um
  token com o mesmo `id` e as mesmas regras deste módulo, sem que o número
  passe pelo nosso servidor. `create/2` existe para o app e para o teste
  automatizado; antes de chamá-lo de um servidor em produção, confira a
  situação PCI da empresa.

  ## Sem token de API

  É a única rota da Iugu sem autenticação: "A API de Criação de Token não
  utiliza a autenticação via api_token". Quem identifica a conta é o
  `account_id` do corpo, "a conta que armazenará o token". Por isso
  `create/2` sai com `api_token: :none` (veja `Iugu.Client`), sem
  o header `Authorization`: a tabela de erros lista `api_token: está
  invalido` para a rota, então um token enviado precisa ser válido, e o da
  conta mestre não é necessariamente o da conta do `account_id`. Num
  marketplace, "é possível enviar um token criado pela conta mestre" numa
  cobrança da subconta.

  ## Uso único e ambiente

  "O token é gerado para uma transação específica." Qualquer chamada a
  `POST /v1/charge` ou a `POST /v1/customers/{id}/payment_methods` consome o
  token, com sucesso **ou falha** (`token não é válido`, `Esse token já foi
  usado`). Para cobrar de novo o mesmo cartão, salve-o como forma de
  pagamento (`Iugu.Customer.create_payment_method/3`) e cobre com
  `customer_payment_method_id`, "infinitas vezes".

  O token é preso ao ambiente em que nasceu: `test: true` cria um token de
  teste, e usá-lo com um `live_api_token` (ou o contrário) responde 400
  `token não é válido`. Um cartão por chamada: "A estrutura desta rota não
  permite adicionar um objeto data extra".

  ## Zero Auth

  `zero_auth/2` valida o cartão sem cobrar (emissor, uso no Brasil, número,
  CVV), de graça. Só produção, só `live_api_token`, só Visa, Master e Elo, e
  precisa ser habilitado pelo suporte da Iugu na conta. Um cartão recusado
  volta como `kind: :declined` com o LR do adquirente.

  ## O que não está confirmado

    * o padrão de `test` quando omitido (o SDK só manda o campo quando o
      chamador informa)
    * se um `api_token` opcional inválido é rejeitado; o SDK não manda nenhum
    * se o Zero Auth consome o token (a documentação não diz; pela regra de
      uso único, assuma que sim e gere outro para a cobrança, ou salve o
      cartão antes)
    * não há número de teste documentado para Elo e Hipercard, nem forma de
      forçar um LR específico no ambiente de teste
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Params
  alias Iugu.Response

  @path "/v1/payment_token"
  @zero_auth_path "/v1/zero_auth"
  @method "credit_card"

  @card_fields ~w(number verification_value first_name last_name month year)

  # Números como a documentação os imprime, menos os espaços que a API tolera
  # mas ninguém quer digitar num teste.
  @test_cards %{
    master_success: "5555555555554444",
    visa_success: "4111111111111111",
    visa_success_alternative: "4242424242424242",
    visa_declined: "4012888888881881",
    amex_success: "378282246310005",
    amex_declined: "371449635398431",
    amex_invalid: "376411112222331",
    diners_success: "30569309025904",
    diners_declined: "38520000023237"
  }

  @type t :: %{
          id: String.t(),
          method: String.t(),
          test?: boolean(),
          brand: String.t() | nil,
          bin: String.t() | nil,
          holder_name: String.t() | nil,
          display_number: String.t() | nil,
          month: integer() | nil,
          year: integer() | nil,
          body: map()
        }

  @doc """
  Cria um token de uso único para um cartão de crédito. Leia o aviso PCI no
  moduledoc antes de chamar isto de um servidor.

  `account_id` é a conta Iugu que guarda o token (32 caracteres hexadecimais,
  sem o `#` do painel). `card` leva os seis campos que a rota exige, em
  átomo ou string: `number` (espaços tolerados), `verification_value` (4
  dígitos na Amex), `first_name`, `last_name`, `month` e `year`. Mês e ano
  aceitam inteiro e saem como a rota pede, `"MM"` e `"AAAA"`; um ano de dois
  dígitos é recusado aqui porque a referência pede quatro. Opção `:test`
  (`true` gera token de teste).

  O `method` é sempre `credit_card`, o único suportado ("atualmente somente
  credit_card"). Cartão inválido responde 422 por campo (`number: is not a
  valid credit card number`, `year: expired`), conta desconhecida 400
  `account_id invalido`.

  Devolve `%{id, method, test?, brand, bin, holder_name, display_number,
  month, year, body}`; um 200 sem `id` é `kind: :unexpected`. Sem retry: a
  rota não tem chave de idempotência, e um token a mais custa pouco, mas o
  cartão fica com uma tentativa a menos no mês.
  """
  @spec create(String.t(), map(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(account_id, card, opts \\ []) when is_binary(account_id) and is_map(card) do
    {token_opts, req_opts} = Keyword.split(opts, [:test])
    card = Params.stringify_keys(card)

    with :ok <- validate_card(card),
         {:ok, body} <-
           Client.post(
             @path,
             build_body(account_id, card, Keyword.get(token_opts, :test)),
             Keyword.put(req_opts, :api_token, :none)
           ) do
      normalize(body)
    end
  end

  @doc """
  Consulta o Zero Auth de um token: valida o cartão no emissor sem cobrar.

  `POST /v1/zero_auth` com `{"token": ...}`, `live_api_token` da conta em
  `api_token:` (ou o padrão do SDK), produção apenas. Devolve
  `{:ok, %{valid?: true, code: "00", message: "Transacao autorizada"}}`
  quando o emissor aprova. Recusa (`{"zero_auth": {"code": "54", "message":
  "Autorizacao negada", "valid": false}}`, HTTP 422) e bandeira fora de Visa,
  Master e Elo (`code` `"57"`, `Bandeira Inválida`) voltam como
  `kind: :declined` com o `code` em `lr`. Token ausente responde 400
  `{"token": ["can't be blank"]}`, sem o envelope `errors`, e fica em
  `kind: :validation` com o corpo cru.
  """
  @spec zero_auth(String.t(), keyword()) ::
          {:ok, %{valid?: boolean(), code: String.t() | nil, message: String.t() | nil}}
          | {:error, Error.t()}
  def zero_auth(token, opts \\ []) when is_binary(token) do
    case Client.post(@zero_auth_path, %{"token" => token}, opts) do
      {:ok, %{"zero_auth" => %{} = result} = body} ->
        if Map.get(result, "valid") == true do
          {:ok,
           %{valid?: true, code: Map.get(result, "code"), message: Map.get(result, "message")}}
        else
          {:error, declined_zero_auth(body, result, 200)}
        end

      {:ok, body} ->
        {:error,
         %Error{
           kind: :unexpected,
           path: @zero_auth_path,
           body: body,
           messages: ["resposta sem zero_auth"]
         }}

      {:error, %Error{body: %{"zero_auth" => %{} = result} = body, status: status}} ->
        {:error, declined_zero_auth(body, result, status)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Cartões de teste documentados, por bandeira e resultado.

  Valem no modo de teste (token criado com `test: true` e cobrança com o
  `test_api_token`); o Zero Auth é só produção e não os aceita. "O CVV da
  Amex são 4 dígitos"; qualquer CVV e validade futura funcionam (os exemplos
  usam `123` e `12/2030`). Os `*_declined` produzem uma cobrança com
  `success: false`, e `amex_invalid` um 422 `number: is not a valid credit
  card number` já na criação do token.
  """
  @spec test_cards() :: %{atom() => String.t()}
  def test_cards, do: @test_cards

  @doc "Número do cartão de teste de um resultado específico, ou `nil`."
  @spec test_card(atom()) :: String.t() | nil
  def test_card(result), do: Map.get(@test_cards, result)

  @doc """
  Cartão de teste pronto para `create/3`, com nome, CVV e validade que a
  documentação usa. O `result` é uma chave de `test_cards/0`.
  """
  @spec test_card_data(atom()) :: map()
  def test_card_data(result) do
    number =
      test_card(result) || raise ArgumentError, "cartão de teste desconhecido: #{inspect(result)}"

    %{
      "number" => number,
      "verification_value" => if(String.starts_with?(number, "3"), do: "1234", else: "123"),
      "first_name" => "Cliente",
      "last_name" => "Teste",
      "month" => "12",
      "year" => "2030"
    }
  end

  defp build_body(account_id, card, test) do
    data =
      card
      |> Map.take(@card_fields)
      |> Map.update!("month", &format_month/1)
      |> Map.update!("year", &to_string/1)

    %{"account_id" => account_id, "method" => @method, "data" => data}
    |> Params.put_present("test", test)
  end

  defp validate_card(card) do
    with :ok <- validate_present(card) do
      cond do
        not valid_month?(Map.get(card, "month")) ->
          validation_error("month deve ser um mês de 01 a 12.")

        not valid_year?(Map.get(card, "year")) ->
          validation_error("year deve ter quatro dígitos (\"2030\"), como a referência pede.")

        not digits_only?(Map.get(card, "number")) ->
          validation_error("number deve conter apenas dígitos (espaços são aceitos).")

        true ->
          :ok
      end
    end
  end

  defp validate_present(card) do
    case Enum.reject(@card_fields, &Params.present?(card, &1)) do
      [] ->
        :ok

      missing ->
        validation_error("Campos do cartão ausentes: #{Enum.join(missing, ", ")}.")
    end
  end

  defp valid_month?(month) when is_integer(month), do: month in 1..12

  defp valid_month?(month) when is_binary(month) do
    case Integer.parse(month) do
      {value, ""} -> value in 1..12
      _other -> false
    end
  end

  defp valid_month?(_month), do: false

  defp valid_year?(year) when is_integer(year), do: year in 1000..9999
  defp valid_year?(year) when is_binary(year), do: Regex.match?(~r/\A\d{4}\z/, year)
  defp valid_year?(_year), do: false

  defp digits_only?(number) when is_binary(number), do: Regex.match?(~r/\A[\d ]+\z/, number)
  defp digits_only?(_number), do: false

  defp format_month(month) when is_integer(month),
    do: month |> Integer.to_string() |> String.pad_leading(2, "0")

  defp format_month(month) when is_binary(month), do: String.pad_leading(month, 2, "0")

  defp normalize(%{"id" => id} = body) when is_binary(id) do
    extra_info = Map.get(body, "extra_info") || %{}

    {:ok,
     %{
       id: id,
       method: Map.get(body, "method"),
       test?: Map.get(body, "test") == true,
       brand: Map.get(extra_info, "brand"),
       bin: Map.get(extra_info, "bin"),
       holder_name: Map.get(extra_info, "holder_name"),
       display_number: Map.get(extra_info, "display_number"),
       month: Response.integer(extra_info, ["month"]),
       year: Response.integer(extra_info, ["year"]),
       body: body
     }}
  end

  defp normalize(body) do
    {:error, %Error{kind: :unexpected, path: @path, body: body, messages: ["resposta sem id"]}}
  end

  defp declined_zero_auth(body, result, status) do
    Error.declined(body, @zero_auth_path,
      lr: Map.get(result, "code"),
      message: Map.get(result, "message"),
      status: status
    )
  end

  defp validation_error(message), do: {:error, Error.validation(message, @path)}
end
