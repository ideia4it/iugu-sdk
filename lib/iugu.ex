defmodule Iugu do
  @moduledoc """
  SDK da Iugu.

  Cobre o marketplace da Iugu e o que gira em volta dele: subcontas com
  verificação KYC, fatura com split, cobrança direta, cliente e cartão salvo,
  saldo, saque, transferência entre contas, Pix e TED para terceiros,
  extratos e webhooks, mais a conta digital do BaaS: pagar boleto com o
  saldo, receber depósito por Pix, QR Code estático e chaves Pix. **Não**
  liga nada disso a nenhuma funcionalidade: aqui só existe cliente HTTP, e
  nenhum schema, contexto, controller ou worker.

  Toda função devolve `{:ok, resultado}` ou `{:error, %Iugu.Error{}}`.
  O que a Iugu recusaria com 4xx e dá para conferir antes de gastar a
  chamada volta como `kind: :validation, status: nil`, sem ir à rede.

  ## O fluxo do marketplace, de ponta a ponta

  A conta mestre é a do marketplace; cada lojista ou profissional que recebe
  dinheiro é uma subconta. O caminho inteiro, com o token de cada passo:

  1. **Criar a subconta**, com o `live_api_token` da mestre (o padrão do SDK)
     e a assinatura RSA da mestre. A resposta é o único lugar em que os três
     tokens da subconta aparecem por inteiro; guarde-os cifrados.

         {:ok, subaccount} =
           Iugu.create_account("Loja Ana",
             splits: [%{recipient_account_id: master_id, percent: 30}]
           )

         subaccount.live_api_token
         subaccount.test_api_token
         subaccount.user_token

  2. **Enviar a verificação KYC**, com o `user_token` da subconta, em até 24
     horas e uma vez só. Enquanto a conta não é verificada, só o
     `test_api_token` dela é aceito no resto da API.

         {:ok, _verification} =
           Iugu.request_account_verification(subaccount.account_id, data, files,
             api_token: subaccount.user_token
           )

  3. **Esperar a aprovação**, que leva até dois dias úteis e chega pelo
     webhook `referrals.verification`. Entre um evento e outro, a leitura da
     conta com o `live_api_token` da própria subconta diz onde ela está.

         {:ok, %{verified?: true, can_receive?: true}} =
           Iugu.get_account(subaccount.account_id,
             api_token: subaccount.live_api_token
           )

  4. **Cobrar com split.** A fatura pertence a quem a cria e quem cria paga
     a taxa da Iugu; o split manda parte do valor para outra conta do mesmo
     marketplace. Com o token padrão a mestre cria e a subconta recebe o
     split; com o `live_api_token` da subconta é ela quem cria.

         {:ok, invoice} =
           Iugu.create_invoice(
             %{
               email: "cliente@example.com",
               due_date: Date.utc_today(),
               items: [%{description: "Corte + escova", quantity: 1, price_cents: 10_000}],
               payable_with: [:pix],
               payer: %{cpf_cnpj: "12345678909", name: "Maria Silva"},
               splits: [Iugu.Split.percent(subaccount.account_id, 70)]
             },
             own_account_id: master_id
           )

         Iugu.invoice_pix(invoice).qrcode_text

  5. **Ler o status.** O pagamento chega pelo webhook `invoice.status_changed`
     e a liquidação do split por `invoice.split_released`; releia a fatura ao
     receber o evento, nunca decida pelo payload sozinho.

         {:ok, invoice} = Iugu.get_invoice(invoice["id"])
         Iugu.invoice_paid?(invoice)

  6. **Ler o saldo da subconta**, com o `live_api_token` dela. Os saldos vêm
     como texto em pt-BR e voltam em centavos inteiros nos campos `*_cents`.

         {:ok, %{balance_available_for_withdraw_cents: available}} =
           Iugu.get_account(subaccount.account_id,
             api_token: subaccount.live_api_token
           )

  7. **Sacar ou transferir.** O saque para o domicílio bancário da subconta
     é assinado, em reais (o SDK recebe centavos), mínimo de R$ 5,00 e sem
     retry; a alternativa é o saque automático em
     `configure_account/2`. A tarifa de saque que o marketplace cobra do
     profissional é uma transferência entre contas Iugu, da subconta para a
     mestre, assinada e com chave de idempotência.

         {:ok, withdraw} =
           Iugu.request_withdraw(subaccount.account_id, available,
             api_token: subaccount.live_api_token
           )

         {:ok, _transfer} =
           Iugu.create_transfer(master_id, 250,
             api_token: subaccount.live_api_token,
             idempotency_key: "saque-\#{withdraw["id"]}"
           )

  ## Qual token em cada chamada

  A Iugu tem quatro tokens, e a rota decide qual serve:

    * `live_api_token` da conta **mestre**: o padrão do SDK
      (`Iugu.Config.api_token!/0`). Cria e lista subcontas,
      desativa, cria faturas e cobranças da mestre, lê a conciliação de
      saques do marketplace
    * `live_api_token` da **subconta**, em `api_token:`: tudo que acontece
      dentro dela (saldo, configuração, domicílio bancário, saque, faturas,
      clientes, webhooks). O `test_api_token` faz o mesmo em modo de teste
    * `user_token` da subconta: só `request_account_verification/4`,
      `update_account/3` e `renew_user_token/1`. Mandar o `live_api_token`
      nessas três é 401
    * `master_token`, um token de tipo "Mestre" criado no painel: só as três
      rotas de tokens de API das subcontas (`create_api_token/4`,
      `list_api_tokens/2`, `delete_api_token/3`)

  Nenhum token precisa de `Bearer`: a autenticação é HTTP Basic com o token
  como usuário e senha vazia, e `Iugu.Client` cuida disso. O 401
  quase nunca é senha errada: subconta ainda não verificada usando o
  `live_api_token`, token pendente de aprovação do administrador, `api_token`
  onde a rota pede `user_token`, e IP fora da lista permitida dão o mesmo 401.

  ## Assinatura RSA

  As rotas que movimentam dinheiro ou criam acesso exigem os headers
  `Request-Time` e `Signature` (mais `X-Signature-Token-Id`, opcional, quando
  a conta tem mais de um token LIVE com RSA), assinados com a chave privada
  RSA cuja pública está cadastrada no painel: criação de subconta,
  configuração de conta, domicílio bancário, saque, transferência entre
  contas, Pix e TED para terceiros e tokens de API. O SDK assina sozinho
  nessas rotas (`sign: true` em `Iugu.Client`) com a chave de
  `Iugu.Config.signature_private_key!/0`; no fluxo whitelabel do
  marketplace a chave é sempre a da **mestre**, mesmo quando o `api_token` é
  o de uma subconta. `validate_signature/2` confere a rotina contra a Iugu
  sem mover dinheiro: rode uma vez ao configurar a conta e a cada troca de
  chave, antes do primeiro saque. A assinatura só existe em produção: com o
  `test_api_token` a Iugu não valida chave nenhuma, e por isso o ciclo de
  vida do marketplace também só existe em produção.

  ## Dinheiro

  Tudo em centavos inteiros, nunca float: `price_cents`, `amount_cents`,
  `cents` dos splits, e os `*_cents` que o SDK deriva dos saldos formatados
  (`"R$ 58,03"`). A única rota da Iugu que recebe reais é o saque
  (`"amount": 500.0`), e `request_withdraw/3` recebe centavos e converte ali.
  `Iugu.Money` faz a ponte com `Decimal` e lê as três grafias de
  dinheiro que a Iugu escreve nas respostas.

  ## Modo de teste

  Não existe host de sandbox: produção e teste usam `https://api.iugu.com`, e
  é o token que escolhe o ambiente. Um `test_api_token` cria faturas,
  clientes, cobranças e webhooks de teste, com 50 requisições por minuto
  (429), 1.000 faturas por dia e cartões de teste em
  `Iugu.PaymentToken.test_cards/0`. O que **não** funciona em teste:
  criação de subconta, assinatura RSA, saque, transferência entre contas,
  Pix e TED para terceiros e Zero Auth.

  ## Webhooks

  A Iugu chama de gatilho, e um gatilho escuta um evento (ou `all`). Ela
  posta `application/x-www-form-urlencoded`, não JSON, sem assinatura: a
  única conferência é o `authorization` cadastrado no gatilho, que volta no
  header `Authorization` de cada entrega (`Iugu.Webhook.Event.authorized?/2`).
  `sync_webhooks/2` cadastra tudo de uma vez, é idempotente e cabe no limite
  de 20 gatilhos por conta; veja `Iugu.Webhook.Sync`, que se chama
  do console remoto do release. A rota que recebe os eventos ainda não
  existe.

  ## O que este SDK deliberadamente não tem

    * assinaturas, planos e carnês: fora do escopo do marketplace
    * antecipação de recebíveis, depósito, ordem de pagamento e as demais
      rotas de BaaS
    * contatos e responsáveis da subconta (`/v1/accounts/{id}/contacts` e
      `/owners`): sem token documentado, ninguém precisa ainda
    * captura parcial, dados de cartão em claro na forma de pagamento salva
      e `splits` na cobrança direta: não existem na API
    * a rota que recebe o webhook, e qualquer ligação com o domínio da
      aplicação que consome a lib
  """

  alias Iugu.Account
  alias Iugu.Charge
  alias Iugu.Client
  alias Iugu.Customer
  alias Iugu.Deposit
  alias Iugu.FinancialStatement
  alias Iugu.Invoice
  alias Iugu.Marketplace
  alias Iugu.PaymentRequest
  alias Iugu.PaymentToken
  alias Iugu.PixKey
  alias Iugu.Split
  alias Iugu.StaticQrCode
  alias Iugu.Transfer
  alias Iugu.TransferRequest
  alias Iugu.Webhook
  alias Iugu.WithdrawRequest

  @doc "Veja `Iugu.Client.validate_signature/2`."
  defdelegate validate_signature(message, opts \\ []), to: Client

  @doc "Veja `Iugu.Marketplace.create_account/2`."
  defdelegate create_account(name, opts \\ []), to: Marketplace

  @doc "Veja `Iugu.Marketplace.creation_in_progress?/1`."
  defdelegate account_creation_in_progress?(error), to: Marketplace, as: :creation_in_progress?

  @doc "Veja `Iugu.Marketplace.list_accounts/1`."
  defdelegate list_accounts(opts \\ []), to: Marketplace

  @doc "Veja `Iugu.Marketplace.stream_accounts/1`."
  defdelegate stream_accounts(opts \\ []), to: Marketplace

  @doc "Veja `Iugu.Marketplace.deactivate_account/2`."
  defdelegate deactivate_account(account_id, opts \\ []), to: Marketplace

  @doc "Veja `Iugu.Marketplace.create_api_token/4`."
  defdelegate create_api_token(account_id, api_type, description, opts \\ []), to: Marketplace

  @doc "Veja `Iugu.Marketplace.list_api_tokens/2`."
  defdelegate list_api_tokens(account_id, opts \\ []), to: Marketplace

  @doc "Veja `Iugu.Marketplace.delete_api_token/3`."
  defdelegate delete_api_token(account_id, token_id, opts \\ []), to: Marketplace

  @doc "Veja `Iugu.Marketplace.api_types/0`."
  defdelegate api_types(), to: Marketplace

  @doc "Veja `Iugu.Account.get/2`."
  defdelegate get_account(account_id, opts \\ []), to: Account, as: :get

  @doc "Veja `Iugu.Account.request_verification/4`."
  defdelegate request_account_verification(account_id, data, files, opts \\ []),
    to: Account,
    as: :request_verification

  @doc "Veja `Iugu.Account.documents/1`."
  defdelegate list_account_documents(opts \\ []), to: Account, as: :documents

  @doc "Veja `Iugu.Account.resend_documents/2`."
  defdelegate resend_account_documents(files, opts \\ []), to: Account, as: :resend_documents

  @doc "Veja `Iugu.Account.configure/2`."
  defdelegate configure_account(settings, opts \\ []), to: Account, as: :configure

  @doc "Veja `Iugu.Account.update/3`."
  defdelegate update_account(account_id, attrs, opts \\ []), to: Account, as: :update

  @doc "Veja `Iugu.Account.set_pix/2`."
  defdelegate set_account_pix(enabled, opts \\ []), to: Account, as: :set_pix

  @doc "Veja `Iugu.Account.bank_verification/2`."
  defdelegate verify_bank_account(bank_account, opts \\ []), to: Account, as: :bank_verification

  @doc "Veja `Iugu.Account.list_bank_verifications/1`."
  defdelegate list_bank_verifications(opts \\ []), to: Account

  @doc "Veja `Iugu.Account.request_withdraw/3`."
  defdelegate request_withdraw(account_id, amount_cents, opts \\ []), to: Account

  @doc "Veja `Iugu.Account.list_banks/1`."
  defdelegate list_banks(opts \\ []), to: Account

  @doc "Veja `Iugu.Account.list_all_banks/1`."
  defdelegate list_all_banks(opts \\ []), to: Account

  @doc "Veja `Iugu.Account.renew_user_token/1`."
  defdelegate renew_user_token(opts \\ []), to: Account

  @doc "Veja `Iugu.Account.person_types/0`."
  defdelegate person_types(), to: Account

  @doc "Veja `Iugu.Account.price_ranges/0`."
  defdelegate price_ranges(), to: Account

  @doc "Veja `Iugu.Account.verification_account_types/0`."
  defdelegate verification_account_types(), to: Account

  @doc "Veja `Iugu.Account.bank_account_types/0`."
  defdelegate bank_account_types(), to: Account

  @doc "Veja `Iugu.Account.document_kinds/0`."
  defdelegate document_kinds(), to: Account

  @doc "Veja `Iugu.Split.current/1`."
  defdelegate current_split(opts \\ []), to: Split, as: :current

  @doc "Veja `Iugu.Split.set_default/2`."
  defdelegate set_default_split(splits, opts \\ []), to: Split, as: :set_default

  @doc "Veja `Iugu.Invoice.create/2`."
  defdelegate create_invoice(attrs, opts \\ []), to: Invoice, as: :create

  @doc "Veja `Iugu.Invoice.get/2`."
  defdelegate get_invoice(invoice_id, opts \\ []), to: Invoice, as: :get

  @doc "Veja `Iugu.Invoice.list/1`."
  defdelegate list_invoices(opts \\ []), to: Invoice, as: :list

  @doc "Veja `Iugu.Invoice.stream/1`."
  defdelegate stream_invoices(opts \\ []), to: Invoice, as: :stream

  @doc "Veja `Iugu.Invoice.cancel/2`."
  defdelegate cancel_invoice(invoice_id, opts \\ []), to: Invoice, as: :cancel

  @doc "Veja `Iugu.Invoice.capture/2`."
  defdelegate capture_invoice(invoice_id, opts \\ []), to: Invoice, as: :capture

  @doc "Veja `Iugu.Invoice.refund/2`."
  defdelegate refund_invoice(invoice_id, opts \\ []), to: Invoice, as: :refund

  @doc "Veja `Iugu.Invoice.partial_refund/3`."
  defdelegate partially_refund_invoice(invoice_id, refund_cents, opts \\ []),
    to: Invoice,
    as: :partial_refund

  @doc "Veja `Iugu.Invoice.duplicate/3`."
  defdelegate duplicate_invoice(invoice_id, attrs, opts \\ []), to: Invoice, as: :duplicate

  @doc "Veja `Iugu.Invoice.reissue_expired/3`."
  defdelegate reissue_expired_invoice(invoice_id, attrs \\ %{}, opts \\ []),
    to: Invoice,
    as: :reissue_expired

  @doc "Veja `Iugu.Invoice.mark_externally_paid/3`."
  defdelegate mark_invoice_externally_paid(invoice_id, external_payment_id, opts \\ []),
    to: Invoice,
    as: :mark_externally_paid

  @doc "Veja `Iugu.Invoice.search_by_external_ids/3`."
  defdelegate search_invoice_by_external_ids(query_field, value, opts \\ []),
    to: Invoice,
    as: :search_by_external_ids

  @doc "Veja `Iugu.Invoice.send_email/2`."
  defdelegate send_invoice_email(invoice_id, opts \\ []), to: Invoice, as: :send_email

  @doc "Veja `Iugu.Invoice.statuses/0`."
  defdelegate invoice_statuses(), to: Invoice, as: :statuses

  @doc "Veja `Iugu.Invoice.payable_with/0`."
  defdelegate invoice_payable_with(), to: Invoice, as: :payable_with

  @doc "Veja `Iugu.Invoice.search_fields/0`."
  defdelegate invoice_search_fields(), to: Invoice, as: :search_fields

  @doc "Veja `Iugu.Invoice.status/1`."
  defdelegate invoice_status(invoice), to: Invoice, as: :status

  @doc "Veja `Iugu.Invoice.paid?/1`."
  defdelegate invoice_paid?(invoice), to: Invoice, as: :paid?

  @doc "Veja `Iugu.Invoice.final?/1`."
  defdelegate invoice_final?(invoice), to: Invoice, as: :final?

  @doc "Veja `Iugu.Invoice.secure_url/1`."
  defdelegate invoice_secure_url(invoice), to: Invoice, as: :secure_url

  @doc "Veja `Iugu.Invoice.pdf_url/1`."
  defdelegate invoice_pdf_url(invoice), to: Invoice, as: :pdf_url

  @doc "Veja `Iugu.Invoice.pix/1`."
  defdelegate invoice_pix(invoice), to: Invoice, as: :pix

  @doc "Veja `Iugu.Invoice.bank_slip/1`."
  defdelegate invoice_bank_slip(invoice), to: Invoice, as: :bank_slip

  @doc "Veja `Iugu.Invoice.splits/1`."
  defdelegate invoice_splits(invoice), to: Invoice, as: :splits

  @doc "Veja `Iugu.Charge.create/2`."
  defdelegate create_charge(attrs, opts \\ []), to: Charge, as: :create

  @doc "Veja `Iugu.Charge.create_with_two_cards/3`."
  defdelegate create_charge_with_two_cards(invoice_id, payments, opts \\ []),
    to: Charge,
    as: :create_with_two_cards

  @doc "Veja `Iugu.Charge.list_transactions/1`."
  defdelegate list_credit_card_transactions(opts \\ []), to: Charge, as: :list_transactions

  @doc "Veja `Iugu.Charge.stream_transactions/1`."
  defdelegate stream_credit_card_transactions(opts \\ []), to: Charge, as: :stream_transactions

  @doc "Veja `Iugu.Charge.transaction_statuses/0`."
  defdelegate credit_card_transaction_statuses(), to: Charge, as: :transaction_statuses

  @doc "Veja `Iugu.Charge.invoice_id/1`."
  defdelegate charge_invoice_id(charge), to: Charge, as: :invoice_id

  @doc "Veja `Iugu.Charge.url/1`."
  defdelegate charge_url(charge), to: Charge, as: :url

  @doc "Veja `Iugu.Charge.pdf_url/1`."
  defdelegate charge_pdf_url(charge), to: Charge, as: :pdf_url

  @doc "Veja `Iugu.Charge.identification/1`."
  defdelegate charge_identification(charge), to: Charge, as: :identification

  @doc "Veja `Iugu.Charge.authorized?/1`."
  defdelegate charge_authorized?(charge), to: Charge, as: :authorized?

  @doc "Veja `Iugu.Charge.lr/1`."
  defdelegate charge_lr(charge), to: Charge, as: :lr

  @doc "Veja `Iugu.Charge.bank_slip/1`."
  defdelegate charge_bank_slip(charge), to: Charge, as: :bank_slip

  @doc "Veja `Iugu.Charge.card/1`."
  defdelegate charge_card(charge), to: Charge, as: :card

  @doc "Veja `Iugu.Charge.lr_category/1`."
  defdelegate lr_category(lr_or_error), to: Charge

  @doc "Veja `Iugu.Customer.create/2`."
  defdelegate create_customer(attrs, opts \\ []), to: Customer, as: :create

  @doc "Veja `Iugu.Customer.get/2`."
  defdelegate get_customer(customer_id, opts \\ []), to: Customer, as: :get

  @doc "Veja `Iugu.Customer.list/1`."
  defdelegate list_customers(opts \\ []), to: Customer, as: :list

  @doc "Veja `Iugu.Customer.stream/1`."
  defdelegate stream_customers(opts), to: Customer, as: :stream

  @doc "Veja `Iugu.Customer.update/3`."
  defdelegate update_customer(customer_id, attrs, opts \\ []), to: Customer, as: :update

  @doc "Veja `Iugu.Customer.set_default_payment_method/3`."
  defdelegate set_customer_default_payment_method(customer_id, payment_method_id, opts \\ []),
    to: Customer,
    as: :set_default_payment_method

  @doc "Veja `Iugu.Customer.share_payment_methods_from/3`."
  defdelegate share_customer_payment_methods_from(
                subaccount_customer_id,
                master_customer_id,
                opts \\ []
              ),
              to: Customer,
              as: :share_payment_methods_from

  @doc "Veja `Iugu.Customer.delete/2`."
  defdelegate delete_customer(customer_id, opts \\ []), to: Customer, as: :delete

  @doc "Veja `Iugu.Customer.create_payment_method/3`."
  defdelegate create_customer_payment_method(customer_id, attrs, opts \\ []),
    to: Customer,
    as: :create_payment_method

  @doc "Veja `Iugu.Customer.list_payment_methods/2`."
  defdelegate list_customer_payment_methods(customer_id, opts \\ []),
    to: Customer,
    as: :list_payment_methods

  @doc "Veja `Iugu.Customer.get_payment_method/3`."
  defdelegate get_customer_payment_method(customer_id, payment_method_id, opts \\ []),
    to: Customer,
    as: :get_payment_method

  @doc "Veja `Iugu.Customer.update_payment_method/4`."
  defdelegate update_customer_payment_method(
                customer_id,
                payment_method_id,
                description,
                opts \\ []
              ),
              to: Customer,
              as: :update_payment_method

  @doc "Veja `Iugu.Customer.delete_payment_method/3`."
  defdelegate delete_customer_payment_method(customer_id, payment_method_id, opts \\ []),
    to: Customer,
    as: :delete_payment_method

  @doc "Veja `Iugu.Customer.default_payment_method_id/1`."
  defdelegate customer_default_payment_method_id(customer),
    to: Customer,
    as: :default_payment_method_id

  @doc "Veja `Iugu.Customer.not_found?/1`."
  defdelegate customer_not_found?(error), to: Customer, as: :not_found?

  @doc "Veja `Iugu.Customer.card/1`."
  defdelegate payment_method_card(payment_method), to: Customer, as: :card

  @doc "Veja `Iugu.PaymentToken.create/3`."
  defdelegate create_payment_token(account_id, card, opts \\ []), to: PaymentToken, as: :create

  @doc "Veja `Iugu.PaymentToken.zero_auth/2`."
  defdelegate zero_auth(token, opts \\ []), to: PaymentToken

  @doc "Veja `Iugu.PaymentToken.test_cards/0`."
  defdelegate test_cards(), to: PaymentToken

  @doc "Veja `Iugu.PaymentToken.test_card/1`."
  defdelegate test_card(result), to: PaymentToken

  @doc "Veja `Iugu.PaymentToken.test_card_data/1`."
  defdelegate test_card_data(result), to: PaymentToken

  @doc "Veja `Iugu.Transfer.create/3`."
  defdelegate create_transfer(receiver_id, amount_cents, opts \\ []), to: Transfer, as: :create

  @doc "Veja `Iugu.Transfer.list/1`."
  defdelegate list_transfers(opts \\ []), to: Transfer, as: :list

  @doc "Veja `Iugu.Transfer.transfer_types/0`."
  defdelegate transfer_types(), to: Transfer

  @doc "Veja `Iugu.TransferRequest.create/2`."
  defdelegate create_transfer_request(attrs, opts \\ []), to: TransferRequest, as: :create

  @doc "Veja `Iugu.TransferRequest.get/2`."
  defdelegate get_transfer_request(transfer_request_id, opts \\ []),
    to: TransferRequest,
    as: :get

  @doc "Veja `Iugu.TransferRequest.list/1`."
  defdelegate list_transfer_requests(opts \\ []), to: TransferRequest, as: :list

  @doc "Veja `Iugu.TransferRequest.stream/1`."
  defdelegate stream_transfer_requests(opts \\ []), to: TransferRequest, as: :stream

  @doc "Veja `Iugu.TransferRequest.cancel_scheduled/2`."
  defdelegate cancel_scheduled_transfer_request(transfer_request_id, opts \\ []),
    to: TransferRequest,
    as: :cancel_scheduled

  @doc "Veja `Iugu.TransferRequest.final?/2`."
  defdelegate transfer_request_final?(transfer_request, now \\ DateTime.utc_now()),
    to: TransferRequest,
    as: :final?

  @doc "Veja `Iugu.TransferRequest.transfer_types/0`."
  defdelegate transfer_request_types(), to: TransferRequest, as: :transfer_types

  @doc "Veja `Iugu.TransferRequest.pix_key_types/0`."
  defdelegate pix_key_types(), to: TransferRequest

  @doc "Veja `Iugu.TransferRequest.account_types/0`."
  defdelegate transfer_request_account_types(), to: TransferRequest, as: :account_types

  @doc "Veja `Iugu.TransferRequest.statuses/0`."
  defdelegate transfer_request_statuses(), to: TransferRequest, as: :statuses

  @doc "Veja `Iugu.TransferRequest.decode_qrcode/2`."
  defdelegate decode_pix_qrcode(payload, opts \\ []), to: TransferRequest, as: :decode_qrcode

  @doc "Veja `Iugu.WithdrawRequest.get/2`."
  defdelegate get_withdraw_request(withdraw_request_id, opts \\ []),
    to: WithdrawRequest,
    as: :get

  @doc "Veja `Iugu.WithdrawRequest.list/1`."
  defdelegate list_withdraw_requests(opts \\ []), to: WithdrawRequest, as: :list

  @doc "Veja `Iugu.WithdrawRequest.conciliation/1`."
  defdelegate withdraw_conciliation(opts \\ []), to: WithdrawRequest, as: :conciliation

  @doc "Veja `Iugu.WithdrawRequest.stream_conciliation/1`."
  defdelegate stream_withdraw_conciliation(opts \\ []),
    to: WithdrawRequest,
    as: :stream_conciliation

  @doc "Veja `Iugu.WithdrawRequest.statuses/0`."
  defdelegate withdraw_request_statuses(), to: WithdrawRequest, as: :statuses

  @doc "Veja `Iugu.WithdrawRequest.conciliation_statuses/0`."
  defdelegate withdraw_conciliation_statuses(), to: WithdrawRequest, as: :conciliation_statuses

  @doc "Veja `Iugu.PaymentRequest.validate_barcode/2`."
  defdelegate validate_payment_barcode(barcode, opts \\ []),
    to: PaymentRequest,
    as: :validate_barcode

  @doc "Veja `Iugu.PaymentRequest.create/2`."
  defdelegate create_payment_request(attrs, opts \\ []), to: PaymentRequest, as: :create

  @doc "Veja `Iugu.PaymentRequest.get/2`."
  defdelegate get_payment_request(payment_request_id, opts \\ []), to: PaymentRequest, as: :get

  @doc "Veja `Iugu.PaymentRequest.list/1`."
  defdelegate list_payment_requests(opts \\ []), to: PaymentRequest, as: :list

  @doc "Veja `Iugu.PaymentRequest.stream/1`."
  defdelegate stream_payment_requests(opts \\ []), to: PaymentRequest, as: :stream

  @doc "Veja `Iugu.PaymentRequest.statuses/0`."
  defdelegate payment_request_statuses(), to: PaymentRequest, as: :statuses

  @doc "Veja `Iugu.Deposit.get/2`."
  defdelegate get_deposit(deposit_id, opts \\ []), to: Deposit, as: :get

  @doc "Veja `Iugu.Deposit.list/1`."
  defdelegate list_deposits(opts \\ []), to: Deposit, as: :list

  @doc "Veja `Iugu.Deposit.stream/1`."
  defdelegate stream_deposits(opts \\ []), to: Deposit, as: :stream

  @doc "Veja `Iugu.Deposit.refund/2`."
  defdelegate refund_deposit(deposit_id, opts \\ []), to: Deposit, as: :refund

  @doc "Veja `Iugu.Deposit.not_found?/1`."
  defdelegate deposit_not_found?(error), to: Deposit, as: :not_found?

  @doc "Veja `Iugu.Deposit.statuses/0`."
  defdelegate deposit_statuses(), to: Deposit, as: :statuses

  @doc "Veja `Iugu.Deposit.deposit_types/0`."
  defdelegate deposit_types(), to: Deposit

  @doc "Veja `Iugu.StaticQrCode.create/2`."
  defdelegate create_static_qr_code(attrs, opts \\ []), to: StaticQrCode, as: :create

  @doc "Veja `Iugu.StaticQrCode.get/2`."
  defdelegate get_static_qr_code(qr_code_id, opts \\ []), to: StaticQrCode, as: :get

  @doc "Veja `Iugu.StaticQrCode.list/1`."
  defdelegate list_static_qr_codes(opts \\ []), to: StaticQrCode, as: :list

  @doc "Veja `Iugu.StaticQrCode.stream/1`."
  defdelegate stream_static_qr_codes(opts \\ []), to: StaticQrCode, as: :stream

  @doc "Veja `Iugu.PixKey.registered/1`."
  defdelegate registered_pix_keys(opts \\ []), to: PixKey, as: :registered

  @doc "Veja `Iugu.PixKey.list/1`."
  defdelegate list_pix_keys(opts \\ []), to: PixKey, as: :list

  @doc "Veja `Iugu.FinancialStatement.financial/1`."
  defdelegate financial_statement(opts \\ []), to: FinancialStatement, as: :financial

  @doc "Veja `Iugu.FinancialStatement.stream_financial/1`."
  defdelegate stream_financial_statement(opts \\ []),
    to: FinancialStatement,
    as: :stream_financial

  @doc "Veja `Iugu.FinancialStatement.invoices_statement/1`."
  defdelegate invoices_statement(opts \\ []), to: FinancialStatement

  @doc "Veja `Iugu.FinancialStatement.consolidated/2`."
  defdelegate consolidated_statement(from, opts \\ []), to: FinancialStatement, as: :consolidated

  @doc "Veja `Iugu.FinancialStatement.settled/2`."
  defdelegate settled_statement(date, opts \\ []), to: FinancialStatement, as: :settled

  @doc "Veja `Iugu.FinancialStatement.receivables/1`."
  defdelegate consolidated_receivables(opts \\ []), to: FinancialStatement, as: :receivables

  @doc "Veja `Iugu.FinancialStatement.invoice_statuses/0`."
  defdelegate statement_invoice_statuses(), to: FinancialStatement, as: :invoice_statuses

  @doc "Veja `Iugu.FinancialStatement.movement_types/0`."
  defdelegate movement_types(), to: FinancialStatement

  @doc "Veja `Iugu.FinancialStatement.movement_type_description/1`."
  defdelegate movement_type_description(movement_type), to: FinancialStatement

  @doc "Veja `Iugu.FinancialStatement.card_brand/1`."
  defdelegate card_brand(transaction_code), to: FinancialStatement

  @doc "Veja `Iugu.Webhook.events/0`."
  defdelegate webhook_events(), to: Webhook, as: :events

  @doc "Veja `Iugu.Webhook.invoice_events/0`."
  defdelegate invoice_webhook_events(), to: Webhook, as: :invoice_events

  @doc "Veja `Iugu.Webhook.subscription_events/0`."
  defdelegate subscription_webhook_events(), to: Webhook, as: :subscription_events

  @doc "Veja `Iugu.Webhook.kyc_events/0`."
  defdelegate kyc_webhook_events(), to: Webhook, as: :kyc_events

  @doc "Veja `Iugu.Webhook.withdraw_events/0`."
  defdelegate withdraw_webhook_events(), to: Webhook, as: :withdraw_events

  @doc "Veja `Iugu.Webhook.transfer_events/0`."
  defdelegate transfer_webhook_events(), to: Webhook, as: :transfer_events

  @doc "Veja `Iugu.Webhook.deposit_events/0`."
  defdelegate deposit_webhook_events(), to: Webhook, as: :deposit_events

  @doc "Veja `Iugu.Webhook.outbound_ip/0`."
  defdelegate webhook_outbound_ip(), to: Webhook, as: :outbound_ip

  @doc "Veja `Iugu.Webhook.list_events/1`."
  defdelegate list_webhook_events(opts \\ []), to: Webhook, as: :list_events

  @doc "Veja `Iugu.Webhook.create/2`."
  defdelegate create_webhook(attrs, opts \\ []), to: Webhook, as: :create

  @doc "Veja `Iugu.Webhook.update/3`."
  defdelegate update_webhook(id, attrs, opts \\ []), to: Webhook, as: :update

  @doc "Veja `Iugu.Webhook.get/2`."
  defdelegate get_webhook(id, opts \\ []), to: Webhook, as: :get

  @doc "Veja `Iugu.Webhook.delete/2`."
  defdelegate delete_webhook(id, opts \\ []), to: Webhook, as: :delete

  @doc "Veja `Iugu.Webhook.list/1`."
  defdelegate list_webhooks(opts \\ []), to: Webhook, as: :list

  @doc "Veja `Iugu.Webhook.resend_by_period/3`."
  defdelegate resend_webhooks_by_period(initial_date, final_date, opts \\ []),
    to: Webhook,
    as: :resend_by_period

  @doc "Veja `Iugu.Webhook.list_logs/2`."
  defdelegate list_webhook_logs(invoice_id, opts \\ []), to: Webhook, as: :list_logs

  @doc "Veja `Iugu.Webhook.force_retry/2`."
  defdelegate force_webhook_retry(log_id, opts \\ []), to: Webhook, as: :force_retry

  @doc "Veja `Iugu.Webhook.Sync.sync/2`."
  defdelegate sync_webhooks(url, opts \\ []), to: Iugu.Webhook.Sync, as: :sync

  @doc "Veja `Iugu.Webhook.Sync.remove_all/2`."
  defdelegate remove_all_webhooks(url, opts \\ []),
    to: Iugu.Webhook.Sync,
    as: :remove_all
end
