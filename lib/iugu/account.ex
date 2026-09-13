defmodule Iugu.Account do
  @moduledoc """
  Subconta: o que acontece dentro de uma conta de pagamento.

  Cobre o ciclo de vida depois que `Iugu.Marketplace.create_account/2`
  devolveu os tokens: verificação KYC, documentos, saldo, configuração,
  domicílio bancário e saque. O que a conta mestre faz **sobre** as
  subcontas (criar, listar, desativar, tokens de API) fica em
  `Iugu.Marketplace`.

  ## Qual token em cada chamada

  Nenhuma função aqui usa o token padrão do SDK por acaso: toda rota deste
  módulo age **como a subconta**, então quem chama passa o token dela em
  `api_token:`. A documentação distingue três:

    * `live_api_token` da subconta: `get/2`, `documents/1`,
      `resend_documents/2`, `configure/2`, `set_pix/2`, `bank_verification/2`,
      `list_bank_verifications/1` e `request_withdraw/3`
    * `user_token` da subconta: `request_verification/4`, `update/3` e
      `renew_user_token/1`. Mandar o `live_api_token` nessas três dá 401
      ("Foi informado `api_token` ao invés do `user_token`")
    * `live_api_token` da conta **mestre**: só serve para `get/2` no próprio
      id da mestre; para ler uma subconta é o token dela

  Enquanto a subconta está pendente de verificação, "somente serão aceitas
  requisições com o `test_api_token`": `live_api_token` e `user_token`
  respondem 401 para tudo. A exceção prática é `request_verification/4`, que
  por definição roda numa conta ainda não verificada; a documentação pede o
  `user_token` nela e não diz se o `test_api_token` também serve, **confirme
  contra a conta**.

  ## Assinatura RSA no fluxo whitelabel

  `configure/2`, `bank_verification/2` e `request_withdraw/3` exigem os
  headers `Request-Time` e `Signature`. A chave pública fica registrada uma
  vez só, na conta mestre; o SDK assina com a chave privada da mestre
  (`Iugu.Config.signature_private_key!/0`) e coloca o
  `live_api_token` da subconta na segunda linha do documento e na requisição.
  É o fluxo que a Iugu chama de whitelabel: "onde for solicitado o `api_token`
  criptografado, insira o `live_api_token` da subconta, por mais que ele não
  seja criptografado." Se a chave não existir na mestre, a resposta é 422
  `Public Key Not Found`.

  ## Verificação: uma vez, em 24 horas

  "Só é possível verificar uma subconta em até 24h após sua criação. Além
  disso, após a primeira chamada 200 OK, não será possível requisitá-la
  novamente." A segunda chamada responde 422 `account: there's already a
  pending verification for this account` ou `account: account already
  verified`. Trocar a conta bancária depois é `bank_verification/2`.

  O resultado é assíncrono, em até dois dias úteis: a conta continua
  `verified?: false` até a aprovação, que chega pelo webhook
  `referrals.verification` e aparece em `get/2` como
  `last_verification_request_status: "accepted"`. Reprovação de documento
  chega por `referrals.document_status_change` e se resolve com
  `resend_documents/2`.

  Os dados precisam ser reais mesmo em teste, nunca os da conta mestre, e o
  CPF/CNPJ tem de ser o titular da conta bancária: "Contas com dados
  divergentes serão desverificadas periodicamente." O campo `bank` é a string
  **exata** da tabela "Lista de Bancos" da documentação (`"Itaú"`,
  `"Bradesco/Next"`, `"Caixa Econômica"`), não o código COMPE; `bank_ag` e
  `bank_cc` seguem o formato daquela tabela, dígito incluso.

  `request_verification/4` recusa aqui, antes da chamada, o que a Iugu
  recusaria com 422 e o que a documentação lista como obrigatório: campos de
  `data` faltando, `person_type` fora de `"Pessoa Física"`/`"Pessoa Jurídica"`,
  CPF e nome ausentes na pessoa física, CNPJ, razão social e responsável
  ausentes na pessoa jurídica, `selfie` ausente, documento de identidade
  ausente (`identification` ou frente e verso) e contrato social ausente na
  pessoa jurídica. Ela **não** valida dígito de agência, formato de CEP nem o
  nome do banco: isso a Iugu faz melhor, com a tabela dela.

  ## Saldo vem como texto

  `GET /v1/accounts/{id}` devolve os saldos formatados em pt-BR (`"R$ 58,03"`,
  `"R$ -2,47"`, `"R$100,00"`). `get/2` os converte para centavos inteiros com
  `Iugu.Money.parse_brl/1` nos campos `*_cents` do mapa
  normalizado. Um saldo que não deu para ler vira `nil`, nunca zero, para
  que um formato novo apareça em vez de virar "conta zerada". O separador de
  milhar como ponto **não está documentado** (nenhum exemplo passa de
  R$ 1.000,00); confirme o primeiro saldo dessa ordem contra a conta.

  ## Saque: reais, mínimo de cinco, sem retry

  `request_withdraw/3` é a única rota da Iugu que recebe dinheiro em reais
  ("Formato: 500.0 para 500 reais"), então o SDK recebe centavos e converte
  ali, uma vez. O mínimo é R$ 5,00 e o valor precisa caber em
  `balance_available_for_withdraw_cents` de `get/2`. A rota não aceita
  `Idempotency-Key`, e um retry depois de timeout pode sacar duas vezes; por
  isso o retry fica desligado mesmo que a opção venha ligada. A liquidação é
  D+1 em dia útil, e o desfecho chega pelo webhook
  `withdraw_request.status_changed`.

  ## O que não está confirmado

    * se `request_verification/4` aceita o `test_api_token` além do `user_token`
    * se `files` aceita Base64 puro; as receitas oficiais mandam data URI
      (`data:text/plain;name=arquivo.pdf;base64,...`) e é o que este módulo
      repassa sem tocar
    * limite por arquivo: 10 MB na referência da verificação, 15 MB no guia e
      no reenvio; fique abaixo de 10
    * `estimated_revenue` da pessoa jurídica: mensal (guia e receita) ou anual
      (OpenAPI); o SDK manda o que recebeu e a documentação se contradiz
    * se o filtro `status` de `GET /v1/account/documents` funciona na query
      string (o OpenAPI o coloca num corpo de GET); `documents/1` filtra do
      lado de cá
    * se `splits` em `configure/2` substitui ou acrescenta aos splits padrão
      existentes
    * qual token autentica `GET /v1/banks` e `GET /v1/bank_verification`
      (assumido: qualquer `api_token` e o `live_api_token` da subconta)
    * se a resposta de `request_withdraw/3` traz mais do que `id`, `status` e
      `receipt_url`, e se ela nasce `accepted` (exemplo) ou `pending` (webhook)
    * os valores de `last_verification_request_status` além de `"accepted"`
      e o significado dos `percent` decimais nos splits da resposta (`0.09`)
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Money
  alias Iugu.Params
  alias Iugu.Response

  @accounts_path "/v1/accounts"
  @configuration_path "/v1/accounts/configuration"
  @documents_path "/v1/account/documents"
  @pix_path "/v1/payments/pix"
  @bank_verification_path "/v1/bank_verification"
  @banks_path "/v1/banks"
  @all_banks_path "/v1/banks/list"
  @renew_user_token_path "/v1/profile/renew_access_token"

  @person_types ["Pessoa Física", "Pessoa Jurídica"]
  @verification_account_types ["Corrente", "Poupança", "Pagamento"]
  @price_ranges ["Até R$ 100,00", "Entre R$ 100,00 e R$ 500,00", "Mais que R$ 500,00"]
  @auto_withdraw_types ["daily", "weekly", "biweekly", "monthly"]
  @auto_advance_types ["daily", "weekly", "monthly", "days_after_payment"]
  @bank_account_types ["cc", "cp", "cpg"]
  @document_kinds [
    "identification",
    "identification_front",
    "identification_back",
    "selfie",
    "address_proof",
    "balance_sheet",
    "social_contract",
    "additional_document_one",
    "additional_document_two"
  ]

  # Tudo que o bloco OpenAPI marca como obrigatório em `data`, independente do
  # tipo de pessoa. Os campos específicos de cada tipo são checados à parte.
  @required_verification_fields [
    "price_range",
    "physical_products",
    "business_type",
    "person_type",
    "automatic_transfer",
    "street",
    "number",
    "district",
    "cep",
    "city",
    "state",
    "telephone",
    "estimated_revenue",
    "bank",
    "bank_ag",
    "account_type",
    "bank_cc",
    "politically_exposed_person",
    "website"
  ]
  @natural_person_fields ["cpf", "name"]
  @legal_entity_fields ["cnpj", "company_name", "resp_name", "resp_cpf"]

  @minimum_withdraw_cents 500

  @type account :: %{
          id: String.t() | nil,
          name: String.t() | nil,
          verified?: boolean(),
          can_receive?: boolean(),
          has_bank_address?: boolean(),
          marketplace?: boolean(),
          last_verification_request_status: String.t() | nil,
          last_verification_request_feedback: String.t() | nil,
          auto_withdraw: boolean(),
          disabled_withdraw: boolean(),
          auto_advance: boolean(),
          auto_advance_type: String.t() | nil,
          balance_cents: integer() | nil,
          balance_available_for_withdraw_cents: integer() | nil,
          balance_in_protest_cents: integer() | nil,
          protected_balance_cents: integer() | nil,
          payable_balance_cents: integer() | nil,
          receivable_balance_cents: integer() | nil,
          commission_balance_cents: integer() | nil,
          customer_minimum_balance_cents: integer() | nil,
          bank_accounts: [map()],
          configuration: map() | nil,
          splits: [map()],
          body: map()
        }

  @doc """
  Informações da conta, com os saldos em centavos.

  Autenticada com o `live_api_token` da própria conta em `api_token:` (a
  mestre lê a si mesma com o token padrão). Sem assinatura.

  O mapa normalizado traz os flags de verificação (`verified?`,
  `can_receive?`, `last_verification_request_status` e `_feedback`), os
  saldos como `*_cents` (`nil` quando a string não deu para ler; veja o
  moduledoc), `auto_withdraw`, `auto_advance`, os splits padrão com o id
  sempre em `"id"` (a Iugu ora escreve `"d"`) e o corpo cru em `:body`.
  """
  @spec get(String.t(), keyword()) :: {:ok, account()} | {:error, Error.t()}
  def get(account_id, opts \\ []) when is_binary(account_id) do
    with {:ok, body} <- Client.get(account_path(account_id), opts) do
      {:ok, normalize_account(body)}
    end
  end

  @doc """
  Envia a verificação KYC da subconta. Uma vez só, em até 24 horas; veja o
  moduledoc.

  Autenticada com o `user_token` da subconta em `api_token:`. Sem assinatura.

  `data` e `files` vão no formato da API, com chaves em átomo ou string. Duas
  conveniências:

    * `estimated_revenue_cents` (inteiro) vira `estimated_revenue` no formato
      `"100.00"` que a rota pede; quem já tem a string manda `estimated_revenue`
    * os arquivos são repassados como chegaram; as receitas oficiais usam data
      URI em Base64

  O que falta ou está fora do enum devolve
  `{:error, %Iugu.Error{kind: :validation, status: nil}}` sem ir à
  Iugu. A resposta 200 ecoa `data` (com `bank_ispb` acrescentado) e traz o
  `id` da verificação, o mesmo `data[id]` do webhook `referrals.verification`.
  """
  @spec request_verification(String.t(), map(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request_verification(account_id, data, files, opts \\ [])
      when is_binary(account_id) and is_map(data) and is_map(files) do
    path = "#{account_path(account_id)}/request_verification"
    data = data |> Params.stringify_keys() |> put_estimated_revenue()
    files = Params.stringify_keys(files)

    with :ok <- validate_verification(data, files, path) do
      Client.post(path, %{"data" => data, "files" => files}, opts)
    end
  end

  @doc """
  Documentos enviados na verificação e o status de cada um.

  Autenticada com o `live_api_token` da subconta em `api_token:`; a mestre
  recebe 400 `Only subaccount are allowed`. A opção `:status` filtra do lado
  de cá (`"requested"`, `"approved"`, `"pending_manual_analysis"`,
  `"processing"`, `"not_approved"`, `"rejected"`, `"expired"`, `"invalid"`).

  Lista vazia "não significa que a conta foi Aprovada (verified), apenas que
  não existe nenhum documento enviado".
  """
  @spec documents(keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def documents(opts \\ []) do
    {filter_opts, req_opts} = Keyword.split(opts, [:status])

    with {:ok, body} <- Client.get(@documents_path, req_opts) do
      {:ok, body |> Response.items() |> filter_status(Keyword.get(filter_opts, :status))}
    end
  end

  @doc """
  Reenvia documentos reprovados pelo time de prevenção à fraude.

  Autenticada com o `live_api_token` da subconta em `api_token:`. Só os
  arquivos que a Iugu pediu (status `"requested"`, ou `data[document_type]`
  do webhook `referrals.document_status_change`) são aceitos; um arquivo em
  `pending_manual_analysis` também pode ser trocado antes da análise. As
  chaves de `files` são as mesmas de `request_verification/4`; outra chave
  devolve erro de validação aqui.
  """
  @spec resend_documents(map(), keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def resend_documents(files, opts \\ []) when is_map(files) and map_size(files) > 0 do
    files = Params.stringify_keys(files)

    with :ok <- validate_document_kinds(files, @documents_path),
         {:ok, body} <- Client.put(@documents_path, %{"files" => files}, opts) do
      {:ok, Response.items(body)}
    end
  end

  @doc """
  Configura a conta: cartão, boleto, multa, juros, saque e adiantamento
  automáticos, notificações e splits padrão.

  Requisição assinada, autenticada com o `live_api_token` da conta que está
  sendo configurada em `api_token:` (fluxo whitelabel; veja o moduledoc). Não
  há `account_id` na rota: a conta configurada é a que autentica. Atualização
  parcial: só o que for enviado muda.

  `settings` vai no formato da API (`credit_card`, `bank_slip`, `fines`,
  `late_payment_fine`, `auto_withdraw`, `auto_withdraw_type`,
  `auto_withdraw_option`, `auto_withdraw_anchor_date`, `auto_advance`,
  `auto_advance_type`, `auto_advance_option`, `splits`, ...), com duas
  conversões: `auto_withdraw_anchor_date` aceita `Date` e
  `customer_minimum_balance_cents` aceita inteiro (a rota o declara como
  string). Pix não entra aqui, é `set_pix/2`.

  As regras que a Iugu descreve e o SDK confere antes da chamada:
  `auto_withdraw_type` em `daily`/`weekly`/`biweekly`/`monthly`; `biweekly`
  exige `auto_withdraw_anchor_date`; `auto_advance: true` exige
  `auto_advance_type` e, fora de `daily`, `auto_advance_option`;
  `payment_email_notification: true` exige o destinatário. O saque agendado
  só roda com `auto_withdraw: true`, e o adiantamento só com a funcionalidade
  liberada pelo suporte.

  A resposta é a conta inteira, normalizada como em `get/2`.
  """
  @spec configure(map(), keyword()) :: {:ok, account()} | {:error, Error.t()}
  def configure(settings, opts \\ []) when is_map(settings) and map_size(settings) > 0 do
    settings = settings |> Params.stringify_keys() |> convert_configuration_values()

    with :ok <- validate_configuration(settings),
         {:ok, body} <- Client.post(@configuration_path, settings, Keyword.put(opts, :sign, true)) do
      {:ok, normalize_account(body)}
    end
  end

  @doc """
  Edita a subconta: site, dias de cobrança e trial de assinaturas, URL de
  retorno, e-mails e agenda de saque automático.

  Autenticada com o `user_token` da subconta em `api_token:`, e só numa conta
  já verificada. Sem assinatura.

  `website` é obrigatório na rota desde 2026-06-08 e precisa começar com
  `http://` ou `https://`, então ele vai em toda chamada, mesmo quando só
  outro campo muda. Nome não se altera por API ("é necessario entrar em
  contato com o nosso suporte"). `auto_withdraw_anchor_date` aceita `Date`.

  A resposta é a conta inteira, normalizada como em `get/2`.
  """
  @spec update(String.t(), map(), keyword()) :: {:ok, account()} | {:error, Error.t()}
  def update(account_id, attrs, opts \\ []) when is_binary(account_id) and is_map(attrs) do
    path = account_path(account_id)
    attrs = attrs |> Params.stringify_keys() |> convert_configuration_values()

    with :ok <- validate_website(Map.get(attrs, "website"), path),
         {:ok, body} <- Client.put(path, attrs, opts) do
      {:ok, normalize_account(body)}
    end
  end

  @doc """
  Liga ou desliga o Pix da conta.

  Autenticada com o `live_api_token` da subconta em `api_token:`. Sem
  assinatura. Ligar "gera uma chave virtual do tipo EVP no Banco Central", e é
  por isso que o nome da subconta não pode ter dígito nem símbolo. Ligar duas
  vezes responde 400 `Conta já possui Pix ativo`; desligar o que já está
  desligado, `Pix must be enabled`. A resposta é `%{"success" => true}`.
  """
  @spec set_pix(boolean(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def set_pix(enabled, opts \\ []) when is_boolean(enabled) do
    Client.put(@pix_path, %{"enable" => enabled}, opts)
  end

  @doc """
  Cadastra ou troca o domicílio bancário que recebe os saques.

  Requisição assinada, autenticada com o `live_api_token` da subconta em
  `api_token:` (whitelabel). A conta precisa estar verificada
  (`Sua conta precisa ser verificada antes de mudar o domicílio bancário`) e
  o titular tem de ser o CPF/CNPJ da verificação.

  Ao contrário de `request_verification/4`, aqui `bank` é o código COMPE
  (`"341"` para o Itaú, `"237"` para Bradesco/Next, `"104"` para a Caixa;
  `list_banks/1` devolve a tabela) e `account_type` é `"cc"`, `"cp"` ou
  `"cpg"`. Os dois são conferidos antes da chamada. Opcionais:
  `automatic_validation` (valida o dígito) e `document` (comprovante em
  Base64).

  O resultado é assíncrono: `%{"success" => true}` agora, `accepted` ou
  `rejected` depois, pelo webhook `referrals.bank_verification` e em
  `list_bank_verifications/1`.
  """
  @spec bank_verification(map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def bank_verification(bank_account, opts \\ []) when is_map(bank_account) do
    bank_account = Params.stringify_keys(bank_account)

    with :ok <- validate_bank_account(bank_account) do
      Client.post(@bank_verification_path, bank_account, Keyword.put(opts, :sign, true))
    end
  end

  @doc """
  Pedidos de domicílio bancário da conta, do mais recente ao mais antigo.

  Autenticada com o `live_api_token` da subconta em `api_token:`. Cada item
  traz `status` (`accepted`/`rejected`), `feedback` com o motivo da recusa e
  `bank` como **nome**, mesmo tendo sido enviado como código. Sem nenhum
  pedido a Iugu responde 400 `Not Found`, que chega como
  `kind: :validation`.
  """
  @spec list_bank_verifications(keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_bank_verifications(opts \\ []) do
    with {:ok, body} <- Client.get(@bank_verification_path, opts) do
      {:ok, Response.items(body)}
    end
  end

  @doc """
  Pede um saque para o domicílio bancário da conta. Veja o moduledoc.

  Requisição assinada, autenticada com o `live_api_token` da conta que saca
  em `api_token:` (a subconta saca o próprio saldo; a mestre, com o token
  padrão e o próprio id). `amount_cents` é inteiro em centavos e vira `amount`
  em reais com duas casas; abaixo de R$ 5,00 devolve erro de validação sem
  ir à Iugu. Opção `:custom_variables`: lista de `%{name, value}` para filtrar
  depois em `GET /v1/withdraw_requests`.

  Nunca repete, mesmo com `retry:` na opção. Com `test_api_token` a rota
  responde 401 `Apenas disponível para o ambiente produção`. A resposta traz
  `id`, `status` e `receipt_url`.
  """
  @spec request_withdraw(String.t(), pos_integer(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def request_withdraw(account_id, amount_cents, opts \\ [])
      when is_binary(account_id) and is_integer(amount_cents) do
    path = "#{account_path(account_id)}/request_withdraw"
    {body_opts, req_opts} = Keyword.split(opts, [:custom_variables])

    with :ok <- validate_withdraw_amount(amount_cents, path) do
      # Jason escreve um Decimal como string JSON, e a rota quer um número
      # ("Formato: 500.0 para 500 reais"); cents/100 como float imprime com no
      # máximo duas casas decimais, então a conversão é exata para o que a Iugu
      # aceita.
      body =
        Params.put_present(
          %{"amount" => amount_cents |> Money.cents_to_reais() |> Decimal.to_float()},
          "custom_variables",
          Keyword.get(body_opts, :custom_variables)
        )

      Client.post(path, body, Keyword.merge(req_opts, sign: true, retry: false))
    end
  end

  @doc """
  Bancos cadastrados na Iugu: `compe`, `name` e `ispb` (pode ser `nil`).

  O `compe` é o `bank` de `bank_verification/2`. O `name` **não** serve como
  `bank` em `request_verification/4`: a grafia difere da tabela da verificação
  (`"C6 Bank"` lá, `"Banco C6"` aqui). Qual token autentica não está
  documentado; o padrão do SDK funciona.
  """
  @spec list_banks(keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_banks(opts \\ []) do
    with {:ok, body} <- Client.get(@banks_path, opts) do
      {:ok, Response.items(body)}
    end
  end

  @doc """
  A tabela inteira do Bacen: `ispb`, `compe` e `name` de cada participante.

  `GET /v1/banks/list` "consulta o ISPB e COMPE de todos os bancos
  cadastrados no Bacen", não só os que a Iugu reconhece em `list_banks/1`:
  é a tabela para preencher `receiver.bank.ispb` de uma transferência para
  uma cooperativa ou fintech sem código COMPE (`compe` vem `nil` nelas). São
  mais de mil linhas e a rota não pagina; guarde o resultado.
  """
  @spec list_all_banks(keyword()) :: {:ok, [map()]} | {:error, Error.t()}
  def list_all_banks(opts \\ []) do
    with {:ok, body} <- Client.get(@all_banks_path, opts) do
      {:ok, Response.items(body)}
    end
  end

  @doc """
  Gera um `user_token` novo para a subconta e devolve só ele.

  Autenticada com o `user_token` **atual** da subconta em `api_token:`; é a
  única forma de recuperar o acesso de usuário depois que o retorno de
  `create_account/2` se perdeu. Guarde o novo antes de descartar o antigo: a
  documentação não diz se o antigo morre na hora.
  """
  @spec renew_user_token(keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def renew_user_token(opts \\ []) do
    with {:ok, body} <- Client.post(@renew_user_token_path, %{}, opts) do
      case body do
        %{"new_user_token" => token} when is_binary(token) and token != "" ->
          {:ok, token}

        _other ->
          {:error,
           %Error{
             kind: :unexpected,
             path: @renew_user_token_path,
             body: body,
             messages: ["resposta sem new_user_token"]
           }}
      end
    end
  end

  @doc "Tipos de pessoa aceitos em `request_verification/4`."
  @spec person_types() :: [String.t()]
  def person_types, do: @person_types

  @doc "Faixas de preço aceitas em `request_verification/4`."
  @spec price_ranges() :: [String.t()]
  def price_ranges, do: @price_ranges

  @doc "Tipos de conta aceitos em `request_verification/4` (nome por extenso)."
  @spec verification_account_types() :: [String.t()]
  def verification_account_types, do: @verification_account_types

  @doc "Tipos de conta aceitos em `bank_verification/2` (código curto)."
  @spec bank_account_types() :: [String.t()]
  def bank_account_types, do: @bank_account_types

  @doc "Chaves de arquivo aceitas em `request_verification/4` e `resend_documents/2`."
  @spec document_kinds() :: [String.t()]
  def document_kinds, do: @document_kinds

  defp normalize_account(body) when is_map(body) do
    %{
      id: Map.get(body, "id"),
      name: Map.get(body, "name"),
      verified?: Response.flag(body, "is_verified"),
      can_receive?: Response.flag(body, "can_receive"),
      has_bank_address?: Response.flag(body, "has_bank_address"),
      marketplace?: Response.flag(body, "marketplace"),
      last_verification_request_status: Map.get(body, "last_verification_request_status"),
      last_verification_request_feedback: Map.get(body, "last_verification_request_feedback"),
      auto_withdraw: Response.flag(body, "auto_withdraw"),
      disabled_withdraw: Response.flag(body, "disabled_withdraw"),
      auto_advance: Response.flag(body, "auto_advance"),
      auto_advance_type: Map.get(body, "auto_advance_type"),
      balance_cents: balance_cents(body, "balance"),
      balance_available_for_withdraw_cents: balance_cents(body, "balance_available_for_withdraw"),
      balance_in_protest_cents: balance_cents(body, "balance_in_protest"),
      protected_balance_cents: balance_cents(body, "protected_balance"),
      payable_balance_cents: balance_cents(body, "payable_balance"),
      receivable_balance_cents: balance_cents(body, "receivable_balance"),
      commission_balance_cents: balance_cents(body, "commission_balance"),
      customer_minimum_balance_cents: Response.integer(body, ["customer_minimum_balance_cents"]),
      bank_accounts: Response.items(body, ["bank_accounts"]),
      configuration: Map.get(body, "configuration"),
      splits: body |> Response.items(["splits"]) |> Enum.map(&normalize_split/1),
      body: body
    }
  end

  defp balance_cents(body, key) do
    case Money.parse_brl(Map.get(body, key)) do
      {:ok, cents} -> cents
      :error -> nil
    end
  end

  # O exemplo de informações da conta escreve o id do split como "d"; o exemplo
  # de configuração escreve "id". Quem lê recebe uma chave só.
  defp normalize_split(%{} = split),
    do: Map.put(split, "id", Response.get_any(split, ["id", "d"]))

  defp normalize_split(split), do: split

  defp filter_status(items, nil), do: items
  defp filter_status(items, status), do: Enum.filter(items, &(Map.get(&1, "status") == status))

  defp put_estimated_revenue(%{"estimated_revenue_cents" => cents} = data)
       when is_integer(cents) do
    data
    |> Map.delete("estimated_revenue_cents")
    |> Map.put("estimated_revenue", cents |> Money.cents_to_reais() |> Decimal.to_string(:normal))
  end

  defp put_estimated_revenue(data), do: data

  defp validate_verification(data, files, path) do
    with :ok <- Params.validate_present(data, @required_verification_fields, path),
         :ok <-
           Params.validate_member(
             Map.get(data, "person_type"),
             @person_types,
             "person_type",
             path
           ),
         :ok <-
           Params.validate_member(
             Map.get(data, "price_range"),
             @price_ranges,
             "price_range",
             path
           ),
         :ok <-
           Params.validate_member(
             Map.get(data, "account_type"),
             @verification_account_types,
             "account_type",
             path
           ),
         :ok <- validate_website(Map.get(data, "website"), path),
         :ok <- validate_person_fields(data, path),
         :ok <- validate_document_kinds(files, path),
         :ok <- validate_identification(files, path) do
      validate_selfie_and_contract(data, files, path)
    end
  end

  defp validate_person_fields(%{"person_type" => "Pessoa Física"} = data, path) do
    Params.validate_present(data, @natural_person_fields, path)
  end

  defp validate_person_fields(data, path),
    do: Params.validate_present(data, @legal_entity_fields, path)

  defp validate_identification(files, path) do
    if Params.present?(files, "identification") or
         (Params.present?(files, "identification_front") and
            Params.present?(files, "identification_back")) do
      :ok
    else
      {:error,
       Error.validation(
         "Envie o documento de identidade em identification (frente e verso juntos) ou em identification_front e identification_back.",
         path
       )}
    end
  end

  defp validate_selfie_and_contract(data, files, path) do
    cond do
      not Params.present?(files, "selfie") ->
        {:error, Error.validation("A selfie é obrigatória na verificação.", path)}

      data["person_type"] == "Pessoa Jurídica" and not Params.present?(files, "social_contract") ->
        {:error, Error.validation("O contrato social é obrigatório para pessoa jurídica.", path)}

      true ->
        :ok
    end
  end

  defp validate_document_kinds(files, path) do
    case Map.keys(files) -- @document_kinds do
      [] ->
        :ok

      unknown ->
        {:error,
         Error.validation(
           "Chaves de arquivo desconhecidas: #{Enum.join(unknown, ", ")}. Use #{Enum.join(@document_kinds, ", ")}.",
           path
         )}
    end
  end

  defp validate_website(website, path) when is_binary(website) and website != "" do
    if String.starts_with?(website, ["http://", "https://"]) do
      :ok
    else
      website_error(path)
    end
  end

  defp validate_website(_website, path), do: website_error(path)

  defp website_error(path) do
    {:error,
     Error.validation("website é obrigatório e deve começar com http:// ou https://.", path)}
  end

  defp convert_configuration_values(settings) do
    settings
    |> Map.new(fn
      {"auto_withdraw_anchor_date", %Date{} = date} ->
        {"auto_withdraw_anchor_date", Date.to_iso8601(date)}

      {"customer_minimum_balance_cents", cents} when is_integer(cents) ->
        {"customer_minimum_balance_cents", Integer.to_string(cents)}

      pair ->
        pair
    end)
  end

  defp validate_configuration(settings) do
    with :ok <-
           Params.validate_member(
             Map.get(settings, "auto_withdraw_type"),
             @auto_withdraw_types,
             "auto_withdraw_type",
             @configuration_path
           ),
         :ok <-
           Params.validate_member(
             Map.get(settings, "auto_advance_type"),
             @auto_advance_types,
             "auto_advance_type",
             @configuration_path
           ),
         :ok <- validate_biweekly_anchor(settings),
         :ok <- validate_auto_advance(settings) do
      validate_notification_receiver(settings)
    end
  end

  defp validate_biweekly_anchor(%{"auto_withdraw_type" => "biweekly"} = settings) do
    if Params.present?(settings, "auto_withdraw_anchor_date") do
      :ok
    else
      {:error,
       Error.validation(
         "auto_withdraw_anchor_date é obrigatório quando auto_withdraw_type é biweekly.",
         @configuration_path
       )}
    end
  end

  defp validate_biweekly_anchor(_settings), do: :ok

  defp validate_auto_advance(%{"auto_advance" => true} = settings) do
    cond do
      not Params.present?(settings, "auto_advance_type") ->
        {:error,
         Error.validation(
           "auto_advance_type é obrigatório quando auto_advance é true.",
           @configuration_path
         )}

      settings["auto_advance_type"] != "daily" and
          not Params.present?(settings, "auto_advance_option") ->
        {:error,
         Error.validation(
           "auto_advance_option é obrigatório quando auto_advance_type não é daily.",
           @configuration_path
         )}

      true ->
        :ok
    end
  end

  defp validate_auto_advance(_settings), do: :ok

  defp validate_notification_receiver(%{"payment_email_notification" => true} = settings) do
    if Params.present?(settings, "payment_email_notification_receiver") do
      :ok
    else
      {:error,
       Error.validation(
         "payment_email_notification_receiver é obrigatório quando payment_email_notification é true.",
         @configuration_path
       )}
    end
  end

  defp validate_notification_receiver(_settings), do: :ok

  defp validate_bank_account(bank_account) do
    with :ok <-
           Params.validate_present(
             bank_account,
             ["agency", "account", "account_type", "bank"],
             @bank_verification_path
           ),
         :ok <-
           Params.validate_member(
             Map.get(bank_account, "account_type"),
             @bank_account_types,
             "account_type",
             @bank_verification_path
           ) do
      validate_compe_code(Map.get(bank_account, "bank"))
    end
  end

  defp validate_compe_code(code) when is_binary(code) do
    if Regex.match?(~r/\A\d{3}\z/, code) do
      :ok
    else
      {:error,
       Error.validation(
         "bank em bank_verification é o código COMPE de três dígitos (\"341\" para o Itaú), não o nome; veja list_banks/1.",
         @bank_verification_path
       )}
    end
  end

  defp validate_compe_code(_code) do
    {:error,
     Error.validation("bank deve ser o código COMPE como string.", @bank_verification_path)}
  end

  defp validate_withdraw_amount(amount_cents, _path) when amount_cents >= @minimum_withdraw_cents,
    do: :ok

  defp validate_withdraw_amount(_amount_cents, path) do
    {:error, Error.validation("O saque mínimo é de R$ 5,00 (500 centavos).", path)}
  end

  defp account_path(account_id), do: "#{@accounts_path}/#{Client.encode_path_segment(account_id)}"
end
