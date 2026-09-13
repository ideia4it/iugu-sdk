# Iugu SDK

Biblioteca Elixir para a API da Iugu, cobrindo o marketplace e o que gira em volta: subcontas
com verificação KYC, fatura com split, cobrança direta, cliente e cartão
salvo, saldo, saque, transferência entre contas, Pix e TED para terceiros,
extratos e webhooks, mais a conta digital do BaaS: pagar boleto com o saldo,
depósito recebido, QR Code estático e chaves Pix.

**A lib não sabe nada do app que a usa.** Não há schema, migration, contexto,
controller nem worker: só cliente HTTP. Ligar isso a agendamento, comissão ou
assinatura é trabalho do app.

Documentação oficial: <https://dev.iugu.com>

## Instalação

Consumida como dependência git:

```elixir
{:iugu_sdk, git: "https://github.com/ideia4it/iugu-sdk.git", tag: "v0.1.0"}
```

```bash
mix deps.get
mix precommit      # compile --warnings-as-errors + format + credo --strict + test
```

## Módulos

| Módulo | Responsabilidade |
|---|---|
| `Iugu` | Fachada; delega para os módulos de recurso |
| `Iugu.Client` | Único ponto que fala HTTP; monta o `Req`, assina quando pedido, normaliza a resposta, monta as opções de `Idempotency-Key` e confere a assinatura em `/v1/signature/validate` |
| `Iugu.Config` | Leitura de `config :iugu_sdk` |
| `Iugu.Params` | Ajudantes dos recursos: omitir `nil`, chave atom ou string, campo obrigatório, valor de uma lista, data e hora no fuso de São Paulo |
| `Iugu.Signature` | Documento de três linhas e assinatura RSA-SHA256 das rotas que exigem |
| `Iugu.Error` | Erro único do SDK, com `kind` classificado e `lr` na recusa de cartão |
| `Iugu.Money` | Centavos ↔ `Decimal`, e leitura das três grafias de dinheiro das respostas |
| `Iugu.Response` | Leitura tolerante do corpo (`items`, `totalItems`, flags com `?`) |
| `Iugu.Pagination` | `start`/`limit` + `page_info` + stream que para na página curta |
| `Iugu.Marketplace` | Conta mestre sobre as subcontas: criar, listar, desativar, tokens de API |
| `Iugu.Account` | Dentro da subconta: KYC, documentos, saldo, configuração, domicílio bancário, saque |
| `Iugu.Split` | Regra de split: struct, validação, split padrão da conta |
| `Iugu.Invoice` | Fatura: criar (com split), ler, listar, cancelar, capturar, reembolsar, segunda via |
| `Iugu.Charge` | Cobrança direta: cartão ou boleto na hora, dois cartões, transações de cartão, tabela de LRs |
| `Iugu.Customer` | Cliente e formas de pagamento salvas, cartão compartilhado entre subcontas |
| `Iugu.PaymentToken` | Token de cartão de uso único, Zero Auth, cartões de teste |
| `Iugu.Transfer` | Transferência entre contas Iugu |
| `Iugu.TransferRequest` | Pix e TED para terceiros |
| `Iugu.WithdrawRequest` | Acompanhamento de saques e conciliação do marketplace |
| `Iugu.PaymentRequest` | Conta digital: validar e pagar boleto com o saldo, acompanhar o pedido |
| `Iugu.Deposit` | Conta digital: depósitos recebidos por Pix, QR Code ou TED, e devolução de Pix |
| `Iugu.StaticQrCode` | Conta digital: QR Code Pix permanente, com ou sem valor |
| `Iugu.PixKey` | Conta digital: chaves Pix da conta, no DICT e com status |
| `Iugu.FinancialStatement` | Extratos: financeiro, de faturas, consolidado, liquidados, recebíveis |
| `Iugu.Webhook` | Gatilhos: cadastrar, alterar, listar, remover, reenviar, logs |
| `Iugu.Webhook.Sync` | Cadastro em massa, idempotente, dentro do limite de gatilhos da conta |
| `Iugu.Webhook.Event` | Normalização do payload recebido (formulário, não JSON) e conferência do `authorization` |

## Fonte da verdade

A referência usada é a documentação em <https://dev.iugu.com>: as páginas de
referência (com os blocos OpenAPI), os guias, as receitas e o changelog,
lidos em 2026-09-03. A Iugu não publica uma especificação OpenAPI única, e
as páginas se contradizem em vários pontos (limites, tokens, formatos de
campo). Onde isso acontece o código segue a página de referência da rota, e
a divergência fica registrada no moduledoc do módulo e na última seção deste
documento.

## Configuração

```elixir
config :iugu_sdk,
  base_url: "https://api.iugu.com",
  api_token: System.get_env("IUGU_API_TOKEN"),
  signature_private_key: System.get_env("IUGU_SIGNATURE_PRIVATE_KEY"),
  signature_token_id: System.get_env("IUGU_SIGNATURE_TOKEN_ID"),
  webhook_authorization: System.get_env("IUGU_WEBHOOK_AUTHORIZATION"),
  receive_timeout: :timer.seconds(30)
```

Quem usa a lib põe isso no `config/runtime.exs` do próprio app. Variáveis de
ambiente sugeridas:

| Variável | O que é |
|---|---|
| `IUGU_API_TOKEN` | `live_api_token` da conta mestre, criado no painel Alia em Configurações > Integrações API e aprovado por um administrador |
| `IUGU_BASE_URL` | `https://api.iugu.com`; não há host de sandbox |
| `IUGU_SIGNATURE_PRIVATE_KEY` | PEM da chave privada RSA cuja pública foi colada no painel ao criar o token de produção |
| `IUGU_SIGNATURE_TOKEN_ID` | Id do token que carrega a chave pública, enviado em `X-Signature-Token-Id` |
| `IUGU_WEBHOOK_AUTHORIZATION` | Segredo cadastrado no campo `authorization` dos gatilhos e devolvido pela Iugu em cada entrega |

A lib não levanta na ausência de nenhuma delas: derrubar o boot do app por
uma variável de uma integração que talvez nem esteja em uso seria pior. O erro
aparece na primeira chamada, em `Iugu.Config.api_token!/0` ou em
`signature_private_key!/0`.

Em teste, `config/test.exs` injeta `plug: {Req.Test, Iugu.Client}` via
`:req_options`, sem chave RSA: os testes que assinam geram um par de
chaves em memória e passam a privada por opção. O app que consome a lib faz o
mesmo no `config/test.exs` dele, e `Iugu.TestHelpers` (na `lib/`, de
propósito) traz `assert_basic/2`, `assert_signed/4` e `generate_key_pair/0`.

## Autenticação e tokens

Header `Authorization: Basic Base64("TOKEN:")`, o token como usuário e senha
vazia. É o que a documentação recomenda; `Bearer` com o mesmo Base64 também
é descrito, mas o exemplo oficial de Bearer mostra `Basic`, então o SDK só
usa Basic.

A Iugu tem quatro tokens, e cada rota aceita um:

| Token | Quem tem | Serve para |
|---|---|---|
| `live_api_token` da mestre | Config (`IUGU_API_TOKEN`), padrão do SDK | Criar e listar subcontas, desativar, faturas e cobranças da mestre, conciliação de saques |
| `live_api_token` da subconta | Resposta de `create_account/2`, guardado cifrado | Tudo dentro da subconta: saldo, configuração, domicílio, saque, faturas, clientes, webhooks |
| `test_api_token` (mestre ou subconta) | Idem | O mesmo que o live, em modo de teste, no mesmo host |
| `user_token` da subconta | Idem | Só `request_verification`, `update` e `renew_user_token` |
| `master_token` | Criado no painel, tipo "Mestre" | Só as rotas de tokens de API das subcontas (`/v1/{account_id}/api_tokens`) |

Os três tokens da subconta aparecem por inteiro **uma vez só**, na resposta
de `POST /v1/marketplace/create_account`; depois só versões mascaradas.
Perder o `user_token` tem saída (`renew_user_token/1`, com o token antigo);
perder o `live_api_token` exige criar outro com o `master_token`.

O 401 quase nunca é senha errada. A documentação lista cinco causas, todas
com o mesmo status e sem corpo: subconta ainda não verificada usando o
`live_api_token` (enquanto pendente, só o `test_api_token` é aceito), token
pendente de aprovação do administrador, `api_token` onde a rota pede
`user_token`, IP fora da lista permitida e token de outra conta.
`Iugu.Error` classifica como `:unauthorized` e a investigação começa
pela configuração, não pela Iugu.

## Assinatura RSA

As rotas de cash out (`/v1/transfer_requests`, `/v1/accounts/{id}/request_withdraw`,
`/v1/transfers`, `/v1/payment_requests`), criação de subconta
(`/v1/marketplace/create_account`), configuração de conta
(`/v1/accounts/configuration`), domicílio bancário (`/v1/bank_verification`)
e tokens de API (`/v1/{account_id}/api_tokens`) exigem dois headers além do
token, `Request-Time` e `Signature`, mais `X-Signature-Token-Id`, opcional,
quando a conta tem mais de um token LIVE com RSA.

A assinatura cobre um documento de exatamente três linhas separadas por `\n`:

```
METHOD|PATH
TOKEN|REQUEST_TIME
BODY
```

`PATH` inclui o `/v1` e os ids reais, sem host e sem query string; `TOKEN` é
o `api_token` cru que autentica a chamada; `REQUEST_TIME` é o mesmo valor,
byte a byte, do header; `BODY` são os bytes exatos enviados. O algoritmo é
SHA-256 com RSA PKCS#1 v1.5, Base64 numa linha só, com o prefixo literal
`signature=`. A Iugu tolera 5 minutos de relógio.

Três coisas que o SDK faz por causa disso e que não são óbvias:

- **A `base_url` é só o host.** O `/v1` fica no caminho de cada recurso
  porque ele faz parte da string assinada; escondê-lo na `base_url` faria a
  assinatura sair errada sem aviso.
- **O corpo é assinado depois de codificado**, num passo do Req anexado após
  `encode_body`, e enviado tal qual. Assinar o mapa e deixar o Req codificar
  de novo produziria `Invalid Signature`.
- **O token vai no header e na query** (`?api_token=`) nas chamadas assinadas,
  porque é o que as receitas oficiais fazem e a documentação não diz se o
  Basic basta ali. A query não entra na string assinada.

No fluxo que a Iugu chama de whitelabel a chave pública fica registrada uma
vez só, na conta **mestre**, e as rotas assinadas da subconta (configuração,
domicílio, saque, transferência) saem com a chave privada da mestre e o
`live_api_token` da **subconta** na segunda linha. Chave ausente é 422
`Public Key Not Found`; relógio fora da tolerância, `Invalid Elapsed Time`.

A assinatura só existe em produção: com o `test_api_token` a Iugu não valida
chave nenhuma. Por consequência o ciclo de vida do marketplace (criar
subconta, sacar, transferir) também só existe em produção.

`Iugu.validate_signature/2` chama `POST /v1/signature/validate`, a
única rota assinada que não move nada: a Iugu responde `"Signature check
successful"` quando chave, relógio e documento estão certos, e 422 `Public
Key Not Found`, `Invalid Elapsed Time` ou `Invalid Signature` quando não.
Rode ao configurar a conta e a cada troca de chave, antes do primeiro saque.
Ela não aceita o fluxo whitelabel ("Este é o único endpoint que o Fluxo
Whitelabel não é compatível"): só o token da própria conta da chave.

## Fluxo do marketplace

A conta mestre é a do marketplace; cada lojista ou profissional que recebe
dinheiro é uma subconta. Na ordem, com o token de cada passo:

1. **Criar a subconta** (`create_account/2`): mestre, assinada. O nome só
   pode ter letras e espaços, porque ele vira a chave Pix EVP no Banco
   Central e a Iugu aceita o nome errado sem avisar; o SDK recusa antes. Uma
   criação por vez por mestre (`account_creation_in_progress?/1` reconhece o
   400 que vale repetir). Sem chave de idempotência: cada chamada que chega
   cria uma subconta com custo de manutenção, e por isso nunca há retry.
   Subconta não se apaga; `deactivate_account/2` é irreversível e assíncrona.
2. **Enviar a verificação KYC** (`request_account_verification/4`):
   `user_token` da subconta, em até 24 horas da criação, uma vez só. Dados
   reais mesmo em teste, nunca os da mestre; o CPF/CNPJ tem de ser o titular
   da conta bancária. `bank` é a string exata da tabela de bancos da
   documentação (`"Itaú"`, `"Bradesco/Next"`), não o COMPE. Arquivos em data
   URI Base64, abaixo de 10 MB.
3. **Esperar a aprovação**: até dois dias úteis, pelo webhook
   `referrals.verification`; reprovação de documento por
   `referrals.document_status_change`, resolvida com
   `resend_account_documents/2`. `get_account/2` com o `live_api_token` da
   subconta mostra `verified?` e `last_verification_request_status`.
4. **Cobrar com split** (`create_invoice/2` com `splits`, ou o split padrão
   da subconta): veja a seção seguinte.
5. **Ler o status**: `invoice.status_changed` avisa, `get_invoice/2` confirma.
6. **Ler o saldo** (`get_account/2`): `balance_cents`,
   `balance_available_for_withdraw_cents`, `receivable_balance_cents`.
7. **Sacar ou transferir**: `request_withdraw/3` para o domicílio bancário da
   subconta, ou saque automático em `configure_account/2`
   (`auto_withdraw_type`); `create_transfer/3` da subconta para a mestre para
   a tarifa que o marketplace cobra.

Trocar a conta bancária depois da verificação é `verify_bank_account/2`
(assinada, COMPE de três dígitos, `cc`/`cp`/`cpg`), com o resultado no
webhook `referrals.bank_verification`.

## Split

"O split é a divisão de valores de uma transação entre uma ou mais contas",
sempre dentro do mesmo marketplace. A mesma regra aparece em três lugares, e
`Iugu.Split` é a representação única:

- **split padrão da conta**: vale para toda fatura futura de quem o
  configura. `current_split/1` lê, `set_default_split/2` (`POST /v1/splits`)
  grava substituindo tudo, `configure_account/2` e `create_account/2` também
  aceitam
- **split por fatura**: `splits` em `create_invoice/2`, "alternativa ao Split
  Padrão" para aquela fatura
- **split por assinatura**: fora do escopo

```elixir
Iugu.create_invoice(
  %{
    email: "cliente@example.com",
    due_date: Date.utc_today(),
    items: [%{description: "Corte + escova", quantity: 1, price_cents: 10_000}],
    payable_with: [:pix],
    payer: %{cpf_cnpj: "12345678909", name: "Maria Silva"},
    splits: [Iugu.Split.percent(subaccount_id, 70)]
  },
  own_account_id: master_id
)
```

Quem cria a fatura paga a taxa da Iugu e fica com o que sobra da divisão;
não existe regra para a própria conta criadora. Daí as duas regras que
`Split.validate/3` confere antes de gastar a chamada:

- **nunca** incluir o `account_id` da conta criadora (422 lá; `:own_account_id`
  aqui)
- a soma **nunca** pode chegar a 100% do valor: a Iugu aceita e ignora o
  split em silêncio, e a criadora recebe tudo

`cents` é valor fixo, `percent` é percentual do total (decimais permitidos),
os dois juntos só com `permit_aggregated: true`. Há variantes por forma de
pagamento (`pix_cents`, `credit_card_percent`...) e por número de parcelas
(`credit_card_1x_cents`...). `Split.total_cents/3` calcula o que as regras
levam de um total, assumindo o pior caso quando a forma de pagamento não é
conhecida.

Não há `splits` na cobrança direta (`/v1/charge`): ali o split entra pelo
split padrão da conta ou criando a fatura com `splits` e cobrando-a com
`invoice_id`.

## Cobrança e status

Duas formas de cobrar:

- **Fatura** (`create_invoice/2`): nasce `pending` com QR Code Pix, boleto e
  página de checkout prontos, conforme `payable_with`. Aceita
  `Idempotency-Key` (opção `:idempotency_key`, que também liga o retry); sem
  ela não há retry, porque um timeout pode ter criado a fatura e enviado por
  e-mail. Abrir `secure_url` custa tarifa: mostre `invoice_pix/1` e
  `invoice_bank_slip/1` na própria tela.
- **Cobrança direta** (`create_charge/2`): cartão de crédito na hora (token de
  uso único de `create_payment_token/3`, cartão salvo ou cartão padrão do
  cliente) ou boleto registrado. Cria uma fatura por baixo. **Pix não existe
  aqui**, só na fatura. A recusa do emissor é **HTTP 200 com `success:
  false`**, que o SDK converte em `%Error{kind: :declined, lr: "51"}`;
  `lr_category/1` diz o que a tela faz em seguida (tentar mais tarde, pedir
  outro cartão, corrigir dados). Aceita `Idempotency-Key` (opção
  `:idempotency_key`, que liga o retry); sem ela não há retry, porque o token
  de cartão morre na primeira resposta e um timeout pode ter cobrado.

Status da fatura: `pending`, `paid`, `canceled`, `in_analysis` (cobrança em
duas etapas, capturar ou cancelar em 7 dias), `draft`, `partially_paid`,
`refunded`, `expired`, `in_protest`, `chargeback`, `externally_paid`.
`invoice_paid?/1` é `paid` estrito; `invoice_final?/1` cobre o que não tem
mais nada a esperar do cliente, lembrando que boleto compensado tarde pode
levar `canceled` ou `expired` a `paid`. O que cada rota de mudança exige está
no moduledoc de `Iugu.Invoice`.

Reembolso: cartão aceita parcial e pede até 180 dias; Pix só integral, 90
dias; **boleto não reembolsa por API**. Com split, o valor reembolsado é
distribuído proporcionalmente entre as contas.

## Saldo e saque

`GET /v1/accounts/{id}` devolve os saldos **como texto em pt-BR**
(`"R$ 58,03"`, `"R$ -2,47"`, `"R$100,00"`), e `get_account/2` os converte para
centavos inteiros nos campos `*_cents`. Um saldo que não deu para ler vira
`nil`, nunca zero.

O saque (`request_withdraw/3`) é a única rota da Iugu que recebe dinheiro em
**reais** (`"amount": 70.0`); o SDK recebe centavos e converte ali. Mínimo de
R$ 5,00, dentro de `balance_available_for_withdraw_cents`, assinado, sem
chave de idempotência e por isso **sem retry mesmo que a opção venha ligada**.
Liquidação em D+1 útil; o desfecho chega por `withdraw_request.status_changed`
e se acompanha em `get_withdraw_request/2`. A mestre concilia todos os saques
do marketplace em `withdraw_conciliation/1`.

Transferência entre contas Iugu (`create_transfer/3`): síncrona, mínimo de 1
centavo, tarifada, assinada, com `Idempotency-Key`. É a receita oficial para
a tarifa de saque: a subconta saca e transfere a tarifa para a mestre. Pix e
TED para conta bancária de terceiros são `create_transfer_request/2`, outra
rota, com um intervalo mínimo de 5 segundos entre pedidos da mesma conta e
um 200 que não é o desfecho (`pending` → `processing` → `done` ou
`rejected`; `done` de TED pode virar `rejected` em 24 horas).

Os extratos (`financial_statement/1`, `invoices_statement/1`,
`consolidated_statement/2`, `settled_statement/2`, `consolidated_receivables/1`)
são a parte menos uniforme da API: `"R$ 1,00"`, `"100.0"`, `"40.00 BRL"` e
inteiros de verdade aparecem em rotas diferentes, e os mapas normalizados
trazem sempre `*_cents` inteiro com o corpo cru em `body`.

## Conta digital (BaaS)

A seção BaaS da referência é a conta Iugu usada como conta bancária, sem
fatura no meio. Metade dela é o que o marketplace já usa (criar conta, KYC,
saldo, saque, Pix e TED para terceiros); a outra metade são quatro
recursos:

- **Pagar boleto com o saldo** (`validate_payment_barcode/2`,
  `create_payment_request/2`, `get_payment_request/2`,
  `list_payment_requests/1`): valide a linha digitável primeiro, que a Iugu
  confere na CIP e devolve valor, multa, juros e se o boleto já foi baixado;
  o pagamento tem de sair **em até 15 minutos** da validação. O pedido é
  assinado, sem `Idempotency-Key` e por isso sem retry: depois de um timeout,
  reencontre o pedido listando por `barcode`. O desfecho chega por
  `payment_request.status_changed` (`pending` → `processing` → `done` ou
  `rejected`).
- **Depósito** (`get_deposit/2`, `list_deposits/1`, `refund_deposit/2`):
  dinheiro que entrou por Pix, QR Code ou TED. Não há rota para esperar um
  depósito; o webhook `deposit.pix_status_changed` (ou `ted_`) é o aviso, e
  desde 2026-08-11 traz também `refunded`. `refund_deposit/2` devolve um Pix
  inteiro ao pagador (`processing_refund` até o `refunded` do webhook). O id
  desconhecido responde **400** `Deposit Not Found`, não 404;
  `deposit_not_found?/1` reconhece as duas formas.
- **QR Code estático** (`create_static_qr_code/2`, `get_static_qr_code/2`,
  `list_static_qr_codes/1`): um Pix copia-e-cola permanente da chave da
  conta, com valor fixo ou livre e descrição de até 25 caracteres. Cada
  pagamento vira um depósito `qrcode` com o `qr_code_id` no webhook. Não há
  rota para apagar.
- **Chaves Pix** (`registered_pix_keys/1`, `list_pix_keys/1`): a chave como
  está no DICT (para mostrar ao pagador) e todas as chaves com status (para
  saber se já vale). **Só produção**: com `test_api_token` a Iugu responde
  401 `Apenas disponível para o ambiente produção`. Cadastrar e portar chave
  é pelo painel; `pix_key.status_changed` avisa.

Duas leituras complementam: `decode_pix_qrcode/2` abre um QR Code Pix
(recebedor, valor, `conciliation_id`, validade) antes de pagá-lo com
`create_transfer_request/2`, e `list_all_banks/1` traz a tabela inteira do
Bacen com ISPB e COMPE (`compe` nulo em cooperativas e fintechs), a fonte
para `receiver.bank.ispb`.

## Webhooks

A Iugu chama de gatilho: um par `(event, url)` numa conta, mestre ou
subconta, com o token da conta dona. `event: "all"` assina tudo num gatilho
só; fora dele, cada evento é um gatilho, e a conta inteira cabe em **20**
(a tabela de erros diz 30). Gatilho repetido é aceito e conta no limite: não
há idempotência.

`Iugu.Webhook.Sync` faz o laço a partir de
`GET /v1/web_hooks/supported_events`, compara por `{url, event}`, cria só o
que falta, corrige o `authorization` divergente por `PUT`, e recusa antes de
escrever um plano que estouraria o limite. Chame do console remoto do release
(`bin/app remote`):

```elixir
url = "https://app.example.com/v1/webhooks/iugu"

# sempre comece pelo dry run
{:ok, plano} = Iugu.sync_webhooks(url, dry_run: true)

{:ok, resultado} =
  Iugu.sync_webhooks(url,
    only: ["invoice.status_changed", "referrals.verification", "withdraw_request.status_changed"]
  )

Iugu.list_webhooks(url: url)
```

O que a Iugu manda para a nossa URL:

- **Formulário, não JSON**: `application/x-www-form-urlencoded` com chaves
  Rails (`event=invoice.status_changed&data[id]=...&data[status]=paid`). Todo
  valor é string, booleano incluído. `Iugu.Webhook.Event.parse/1`
  recebe o que o `Plug.Parsers.URLENCODED` entrega.
- **Sem assinatura.** A única conferência é o `authorization` cadastrado no
  gatilho, devolvido no header `Authorization` de cada entrega;
  `Event.authorized?/2` compara em tempo constante com
  `IUGU_WEBHOOK_AUTHORIZATION`, aceitando o valor cru e `Basic base64(valor)`
  porque a documentação não diz qual dos dois. O IP de saída para allowlist
  é `98.82.243.132`.
- **Retentativa automática não documentada.** O que existe é o caminho
  manual: `list_webhook_logs/2`, `force_webhook_retry/2` e
  `resend_webhooks_by_period/3`, que repetem o payload original tal qual. O
  receptor responde 2xx na hora e deduplica por `Event.idempotency_key/1`.

A rota que **recebe** o webhook ainda não existe. Quando for criada, ela
responde 200 na hora e processa em job, e para dinheiro relê o objeto na API
antes de agir.

## Modo de teste

Não existe host de sandbox: produção e teste usam `https://api.iugu.com`, e é
o token (`live_api_token` ou `test_api_token`) que escolhe o ambiente. Em
dev, `api_token` recebe um `test_api_token`.

| | Funciona em teste | Só em produção |
|---|---|---|
| Fatura, cliente, cobrança direta, token de cartão, webhook | sim | |
| Criação de subconta, tokens de API | | sim |
| Assinatura RSA | | sim (com token de teste a Iugu não valida chave) |
| Saque, transferência entre contas, Pix e TED para terceiros | | sim |
| Zero Auth | | sim |
| Extratos com movimentação | | sim ("somente em modo produção há movimentação de saldo") |

Limites do modo de teste: 50 requisições por minuto (429), 1.000 faturas
por dia, 30 itens por fatura, e o `pix.qrcode_text` é uma URL falsa em vez do
payload EMV. Cartões de teste em `Iugu.PaymentToken.test_cards/0`
(`5555 5555 5555 4444` Master aprovado, `4111 1111 1111 1111` Visa aprovado,
`4012 8888 8888 1881` Visa recusado; Amex e Diners também). Não há número de
teste para Elo e Hipercard, nem forma de forçar um LR específico.

## Retry

`Client.get/2` repete falha transitória; `post/3`, `put/3` e `delete/2` não
repetem por padrão. A maioria das rotas de escrita da Iugu não aceita chave
de idempotência (saque, criação de subconta, configuração de conta, tokens de
API, gatilhos), e um retry em timeout gera uma segunda movimentação. As que
aceitam `Idempotency-Key` (fatura, cobrança direta, cliente, transferência
entre contas, Pix e TED para terceiros) ligam o retry quando o chamador passa
`:idempotency_key`, com `:transient` e não `:safe_transient` (este só repete
um POST em 429 e 503, nunca em timeout); `Iugu.Client.idempotency_options/2`
monta essas opções para todas. Sem a chave, essas rotas, o saque e a criação
de subconta forçam o retry desligado mesmo com a opção ligada.

## O que este SDK não tem, e por quê

| Ausente | Motivo |
|---|---|
| Assinaturas, planos, carnês | Fora do escopo do marketplace |
| Antecipação de recebíveis, contestação de chargeback, e-mails, Pix Automático | Idem |
| Contatos e responsáveis da subconta (`/contacts`, `/owners`) | Sem token documentado; ninguém precisa ainda |
| `splits` na cobrança direta | Não existe na API: split padrão da conta ou fatura com `splits` + `invoice_id` |
| Pix na cobrança direta | Não existe na API: `create_invoice/2` com `payable_with: [:pix]` |
| Captura parcial | Não documentada |
| Dados de cartão em claro na forma de pagamento salva | A rota só aceita token |
| `GET /v1/transfers/{id}` e `stream` de transferências | Rota não documentada; se `limit` vale para `sent` e `received` juntos não está claro |
| A rota que recebe o webhook | Entra com a funcionalidade que for consumir os eventos |

## Decisões e pontos não confirmados

Tudo abaixo vem dos pontos marcados `UNCONFIRMED` na pesquisa da documentação
que precedeu o código e dos moduledocs dos módulos. Nada disso foi conferido
contra uma conta real: quem for ligar o SDK a uma funcionalidade confirma o
que a funcionalidade tocar, e atualiza aqui.

### Autenticação e assinatura

- Se uma requisição assinada pode autenticar só pelo `Authorization: Basic`
  em vez de `?api_token=`; o SDK manda os dois
- Se `Authorization: Bearer <token cru>` é aceito (a documentação descreve
  Bearer com o Base64); o SDK usa Basic
- A terceira linha do documento assinado num GET sem corpo (`GET
  /v1/{account_id}/api_tokens`): assumida vazia, com o documento terminando
  no `\n`; nenhuma receita oficial mostra o caso
- Se `DELETE /v1/{account_id}/api_tokens/{id}` valida de fato os headers RSA
  (o OpenAPI os declara, a tabela de rotas obrigatórias não o lista); o SDK
  assina
- Status e corpo de `Public Key Not Found`, `Invalid Elapsed Time` e `Invalid
  Signature` (a tabela de erros diz 422 em `/v1/transfers`; assumido
  `{"errors": "..."}` nas demais)
- Se CRLF é aceito como separador de linha; o SDK usa LF e não põe quebra
  depois do `BODY`
- Corpo do 401 (nenhum documentado), do 429 do modo de teste e presença de
  `Retry-After`; 403 não aparece em nenhuma página
- Se `api_type` aceita algo além de `LIVE` e `TEST`; os valores de
  `live_token_status`/`test_token_status` além de `active`; se
  `GET /v1/{account_id}/api_tokens` com id de subconta restringe a lista e se
  vários tokens LIVE por conta aparecem
- Se o `user_token` antigo morre na hora em `renew_user_token/1`
- O formato do token (64 hexadecimais em todo exemplo) nunca é declarado como
  regra; o SDK não valida
- Nenhuma listagem documenta parâmetro de ordenação; a ordem é sempre da mais
  recente à mais antiga
- O host `https://api.iugu.test` que aparece comentado numa receita Ruby é
  interno da Iugu e não deve ser usado

### Marketplace e subconta

- Se `request_verification/4` aceita o `test_api_token` além do `user_token`
  (a documentação pede `user_token` numa rota que por definição roda em conta
  não verificada, onde só o `test_api_token` é aceito)
- Se `files` aceita Base64 puro sem o prefixo `data:`; as receitas mandam
  data URI e o SDK repassa sem tocar
- Limite por arquivo: 10 MB (referência) ou 15 MB (guia e reenvio)
- `estimated_revenue` da pessoa jurídica: mensal (guia e receita) ou anual
  (OpenAPI)
- Se o filtro `status` de `GET /v1/account/documents` funciona na query
  string (o OpenAPI o coloca num corpo de GET); `list_account_documents/1`
  filtra do lado de cá
- A lista completa de `kind` em `GET /v1/account/documents` (só `selfie` e
  `identification` aparecem) e os valores de `last_verification_request_status`
  além de `accepted` (um `pending` durante a análise é provável)
- Se `splits` em `POST /v1/accounts/configuration` substitui ou acrescenta
  aos splits padrão existentes
- Separador de milhar nos saldos (assumido `.`; nenhum exemplo passa de
  R$ 1.000,00) e o significado dos `percent` decimais nas respostas (`0.09`
  é 0,09% ou 9%?)
- Qual conta (mestre ou subconta) deve cadastrar os gatilhos `referrals.*`;
  na prática os marketplaces cadastram na mestre e `data[account_id]` sempre
  identifica a subconta
- Se `subaccounts_negative_balance_total` aparece só na mestre; a forma de
  `commissions` (sempre `null`) e como se configuram comissões por API
- Qual token autentica `GET /v1/marketplace` (assumido: mestre),
  `GET /v1/banks` e `GET /v1/bank_verification` (assumido: qualquer
  `api_token` e o `live_api_token` da subconta)
- Se `POST /v1/accounts/configuration` pode ser chamado com o token da mestre
  para configurar uma subconta (não há `account_id` na rota, então a conta
  configurada é a que autentica)
- `totalItems` em `GET /v1/marketplace`: total ou tamanho da página; se o
  teto de 10.000 registros da paginação vale ali. `stream_accounts/1` não
  olha para ele
- O que acontece depois de uma `referrals.verification` `rejected`: se
  `request_verification` pode ser repetida ou só o suporte resolve
- Se a desativação dispara webhook, e a mensagem do 400 quando a conta ainda
  tem saldo (a documentação mostra `{}`)
- Valor mínimo de um split (o mínimo de 100 centavos é regra de item de
  fatura)
- Se `PUT /v1/accounts/{id}/owners/{id}` aceita corpo JSON (o OpenAPI declara
  query); rotas não implementadas
- Nenhum limite de requisições nem 429 documentado para esta área

### Split e fatura

- Se o `splits` da fatura substitui ou se soma ao split padrão da conta
  ("alternativa" sugere substituir), e a precedência entre campo genérico,
  por forma de pagamento e por parcela dentro de uma regra
- Qual token `POST /v1/splits` e `GET /v1/splits/current` aceitam (só
  "`api_token`" é dito), o que `current_split/1` devolve sem split (404 ou
  `split_rules` vazio) e como remover o split padrão (nenhuma rota de
  exclusão; lista vazia é a aposta)
- O arredondamento que a Iugu aplica ao percentual; `Split.total_cents/3`
  arredonda meio para cima
- Se o `api_token` precisa ir no corpo das rotas assinadas ou só na query
  (o passo 10 de um guia diz corpo; os curls usam query)
- Faixas efetivas: `expires_in` (0..120 ou 1..30), `bank_slip_extra_due`
  (1..120 ou 1..30), horizonte de `due_date` (3 ou 4 anos); se `expires_in`
  aceita data como num guia (o SDK aceita inteiro e `Date`)
- Se `status_filter` aceita `in_analysis`, `in_protest`, `chargeback` e
  `draft`, e o significado de `authorized` (provavelmente a autorização da
  cobrança em duas etapas vista pelos webhooks)
- O status depois de um reembolso parcial (o evento existe, a tabela de
  status não tem valor para ele)
- Forma do 404 em `GET /v1/invoices/{id}` e em `resource_search` (assumido
  `{"errors": "Invoice Not Found"}`), e o comportamento da busca com mais de
  um resultado
- Se `totalItems` respeita os filtros (a documentação diz que é o total da
  conta) e se o teto de 10.000 da paginação vale para faturas
- TTL da chave de idempotência e corpo do 409; limite diário de faturas em
  produção (existe, valor por conta); limite de requisições em produção
- Forma de `credit_card_transaction` e `financial_return_dates` (sempre
  `null`); valores de `pix.status` além de `qr_code_created` e `paid`
- Se os filtros de data aceitam `Z` além de `-03:00` (o SDK converte para o
  horário de São Paulo) e se `pix_qr_code_expires_at` aceita `Z` além do
  `-00:00` documentado
- Captura parcial não documentada (`remaining_captured_cents` existe na
  resposta); não implementada
- Nos webhooks de fatura, o nome do campo do estado do boleto em
  `invoice.bank_slip_status` (provavelmente `data[status]`) e o do LR em
  `invoice.payment_failed` (provavelmente `data[lr]`): as tabelas estão
  truncadas

### Cobrança direta, cliente e token de cartão

- O JSON exato de uma recusa em `/v1/charge` (`status`, `message`, `errors`,
  se `invoice_id` vem); só a linha de log "LR: 05" está documentada
- O `status` da resposta em modo duas etapas (`authorized`?)
- Se `order_id` impede a duplicata ou é só informativo; a página de
  idempotência lista a rota, a página da rota não menciona o header, e o SDK
  segue a primeira
- Se `email` é obrigatório com `customer_id` e sem `invoice_id` (a receita
  cobra sem `email`); se o total precisa passar de R$ 1,00 estritamente (o
  SDK exige 100 centavos)
- Se o boleto exige `payer.address` hoje (o exemplo omite, o 422 exige); se o
  limite diário de faturas vale para as criadas pela cobrança direta; se o
  split padrão da subconta se aplica a elas
- Dois cartões: se as parcelas precisam somar o total da fatura, o que
  acontece quando só um é aprovado, se `invoice_id` é validado como
  obrigatório
- Se o Zero Auth consome o token (assumido que sim); o padrão de `test` em
  `POST /v1/payment_token` quando omitido; se um `api_token` opcional
  inválido é rejeitado nessa rota
- `totalItems` em `GET /v1/customers` (a descrição diz tamanho da página, o
  exemplo mostra 57 ao lado de 3 itens); se `payment_methods` dentro do
  cliente vem preenchido algum dia
- Remoção de forma de pagamento: efeito sobre `default_payment_method_id`,
  recusa quando uma assinatura a usa, o que um segundo `DELETE` responde; a
  mensagem do 400 ao remover cliente com assinatura
- Se um token `test: true` pode ser salvo numa conta live; se `fingerprint` é
  estável entre contas
- Cartão compartilhado: se a subconta deve mandar o próprio `customer_id`
  junto do `customer_payment_method_id` da mestre, e se os cartões
  compartilhados aparecem na lista da subconta
- Nenhum cartão de teste para Elo e Hipercard, nenhuma forma de forçar um LR
  no modo de teste, nenhum limite de requisições documentado

### Saldo, saque e transferências

- Se `GET /v1/withdraw_conciliations` exige assinatura RSA (um aviso solto na
  tabela de erros sugere que sim; a página da rota não declara); o SDK não
  assina, e um 422 `Public Key Not Found` ali é o sinal para `sign: true`
- Se `POST /v1/accounts/{id}/request_withdraw` honra `Idempotency-Key` (não
  documentado; o SDK não confia); se o `id` da rota aceita o da própria
  mestre
- Se a resposta do saque traz mais do que `id`, `status` e `receipt_url`, e
  se ela nasce `accepted` (exemplo) ou `pending` (webhook); o envelope do 422
- Se `GET /v1/withdraw_requests` aceita `start`/`limit`; se a mestre enxerga
  os saques das subcontas ali; se `GET /{id}` traz `paying_at`,
  `custom_variables`, `receipt_url`, `agreement_effect` como a listagem, e a
  forma do 404
- Transições de saque além de `pending → processing → accepted | rejected`;
  o máximo de `limit` na conciliação
- Transferência entre contas: se `limit` vale para `sent` e `received` juntos
  ou para cada; qual campo `created_at_from/to` filtra e em que formato;
  corpo do 409 e TTL da chave; valor da tarifa; não há `GET /v1/transfers/{id}`
- Pix e TED para terceiros: status HTTP do erro de intervalo de 5 segundos e
  o envelope dos 400 (a documentação mostra `{}`); se `receiver.bank.compe`
  ainda é aceito (só o guia o cita); valores de `qrcode_type`; se
  `end_to_end_id` vem `null` ou ausente numa TED; se `query` na listagem é
  de fato opcional (o OpenAPI o marca `in: path, required` sem placeholder);
  qual das duas formas documentadas de `GET /{id}` a produção devolve; se
  `receipt_url` exige autenticação; se o sandbox aceita a chamada sem
  assinatura; se o status `error` dos webhooks é terminal; a barra final da
  listagem (enviada como documentado)
- Extratos: o vocabulário de `transaction_type` e `reference_type` (só
  `misc`, `Invoice` e `Transfer` aparecem); o envelope de `mon out of range` e
  `mday out of range`; o período padrão sem filtro; se `date` é obrigatório em
  `settled_statement/2` (o SDK exige) e a forma dos itens de `transactions`
  ali; se a mestre lê o extrato de uma subconta por parâmetro (nenhum
  documentado); se o extrato de faturas aceita o `test_api_token`
- Nenhum 429 documentado para estas rotas

### Conta digital (BaaS)

- Pagar boleto: o envelope do 422 de `create_payment_request/2` (saldo
  insuficiente, janela dos 15 minutos vencida, convênio fora da lista) e se
  a validação expirada é 400 ou 422; se a rota aceita `Idempotency-Key` sem
  documentar (o SDK não confia); se `GET /v1/payment_requests` traz
  `totalItems` (o exemplo é uma lista crua) e se a mestre enxerga os pedidos
  das subcontas; status além dos quatro do filtro; a barra final que a
  referência escreve nas rotas (os curls não a têm; o SDK segue os curls)
- Depósito: se nasce num estado anterior a `accepted`; se a listagem traz
  `totalItems` e algum filtro além de `start`/`limit`; o prazo para devolver
  um Pix e se a devolução aceita valor parcial (a rota não tem corpo); se a
  mestre enxerga os depósitos das subcontas; `amount` vem em duas grafias
  nos exemplos (`R$50,00` e `R$549.20`), o SDK lê `amount_cents`
- QR Code estático: se `amount_cents` vai como inteiro ou string (a
  referência declara string e exemplifica inteiro; o SDK manda inteiro);
  valor mínimo; forma do 404; máximo de `limit` (o SDK prende a 100); o que
  a rota responde com `test_api_token`
- Chaves Pix: os valores de `status` além de `active` e de `type` além de
  `evp`; se `registered_pix_keys/1` devolve mais de uma chave quando o
  titular trouxe a sua, e a forma da resposta sem chave
- `decode_pix_qrcode/2`: os valores de `type` além de `dynamic_qr_code`; a
  página mostra um 400 `status_does_not_allow_answer` que parece de outra
  rota
- `list_all_banks/1`: tamanho real da tabela (mais de mil linhas, sem
  paginação) e com que frequência a Iugu a atualiza

### Webhooks

- Se a Iugu manda o `authorization` cru ou como `Basic base64(...)` no header
  `Authorization`; `Event.authorized?/2` aceita os dois
- Se as chaves documentadas sem o prefixo `data[]` (`transfer_request.*`,
  `deposit.pix_status_changed`, `payment_request.created`) e as com o nome do
  evento em `data[event]` (`transfer.*`, `invoice.split_installment_released`,
  `deposit.ted_status_changed`) são diferenças reais no que chega ou descuido
  da documentação; `Event.parse/1` lê as duas formas
- Se `data[transaction_ids]` pode chegar repetido (`data[transaction_ids][]`)
- Se `active` pode ser alterado pela API (nenhum parâmetro documentado o
  liga); se `authorization: nil` em `update_webhook/3` limpa o segredo
- 20 ou 30 gatilhos por conta (o SDK trabalha com 20; `max_triggers:` ajusta)
- Se um gatilho criado com `test_api_token` dispara só para objetos de teste
  e um com `live_api_token` só para produção
- Se `initial_date`, `final_date` e `event` são obrigatórios em
  `resend_webhooks_by_period/3`, se a janela precisa estar toda no passado há
  mais de 3 dias, e se um corpo JSON também é aceito (o SDK manda query)
- Se `GET /v1/web_hook_logs/{id}` aceita id de outro objeto além de fatura;
  os valores de `status` e `error` numa entrega que falhou
- A política de retentativa automática das entregas (contagem, backoff,
  quais códigos repetem): não documentada em nenhuma página; o único artigo
  do suporte está atrás de um desafio do Cloudflare
- O verbo da entrega (`POST` em todos os exemplos, nunca declarado)
- Forma do 404 de id desconhecido em `get`, `update` e `delete` de gatilho, e
  se um segundo `delete` é 404; se `GET /v1/web_hooks` devolve array (o
  OpenAPI mostra um objeto solto, aceito também)
- Payloads de `invoice.partially_refunded`, `invoice.refund_reverted`,
  `invoice.rejected`, `transfer_request.ted_status_changed`,
  `transfer_request.refunded`, `transfer_request.partially_refunded` e
  `pix_key.status_changed`, que `list_webhook_events/1` devolve mas não têm
  página
- Se o valor de `data[document_type]` chega com o erro de digitação da
  documentação (`additiconal_document_one`); `Event.document_type/1` corrige
  as duas grafias
- Se um gatilho `referrals.*` na conta mestre recebe os eventos de todas as
  subcontas (`data[account_id]` identifica a subconta, o que sugere que sim);
  se `referrals.document_status_change` está disponível para todo tipo de
  conta
- Envelope do 422 de validação dos gatilhos (assumido
  `{"errors": {"url": ["não é uma url válida"]}}`) e corpo do 401

## Referências

- <https://dev.iugu.com>
