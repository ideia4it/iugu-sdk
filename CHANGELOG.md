# Changelog

## v0.1.1

Correções da revisão de 2026-09-16. Duas mudam o que um consumidor pode ter
guardado ou chamado; leia antes de subir a tag.

### Mudanças que pedem atenção

- `Iugu.Webhook.Event.idempotency_key/1` passa a incluir `installment` e
  `recipient_account_id` quando o evento os traz
  (`invoice.installment_released`, `invoice.split_installment_released`).
  Antes todas as parcelas e todos os destinatários de uma fatura caíam na
  mesma chave e o consumidor descartava as liberações a partir da segunda.
  Chaves dessas entregas gravadas com a 0.1.0 não batem mais com o replay:
  reconstrua-as a partir dos payloads já processados
  (`Event.parse/1` + `idempotency_key/1`), ou trate as entregas antigas por
  um corte de data. Não aceite a chave antiga como prova de que todas as
  parcelas foram processadas, porque é exatamente isso que perdia dinheiro.
- `Iugu.Pagination.params/2` não monta mais `sortby`. A única listagem com
  ordenação documentada é a de comprovantes de transferência para terceiros,
  cuja grafia é `sortBy`, montada agora em `Iugu.TransferRequest.list/1`.
  Quem chamava o helper direto com `sort_by:` passa a receber `%{}`.

### Correções

- `Iugu.Client` nunca segue redirect (`redirect: false`, imposto depois de
  `:req_options` e da opção da chamada): um 3xx reenviaria token, assinatura
  e corpo ao host apontado.
- `retry: false` forçado em toda rota que move dinheiro sem `Idempotency-Key`
  documentada: devolução de depósito, captura, reembolso e reembolso parcial
  de fatura, cobrança em dois cartões.
- Pagar boleto (`create_payment_request/2`) aceita `:idempotency_key`; a
  página de idempotência da Iugu lista a rota desde 16/09/2026.
- `create_account/2` e `configure_account/2` validam os splits padrão como a
  fatura já fazia; a soma que alcança 100% é aceita pela Iugu e ignorada em
  silêncio.
- `Iugu.Split.validate/3` e `total_cents/3` somam por cenário de pagamento
  (forma e parcelamento): 60% só no Pix e 60% só no cartão deixam de ser
  recusados como 120%.
- Listagem de comprovantes de transferência: `sortBy`, filtros
  `created_at_from/to` e datas em `AAAA-MM-DD` como a referência declara.
- `Iugu.Webhook.Sync`: exclusões antes das criações; se uma exclusão falhar e
  a conta seguir no limite, nada é criado e cada evento volta em `:failed`;
  entre uma duplicata ativa e uma inativa, sobrevive a ativa.

## v0.1.0

Primeira versão: marketplace, split, cobrança, conta digital (BaaS) e
webhooks.
