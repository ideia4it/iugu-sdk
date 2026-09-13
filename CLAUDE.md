# Iugu SDK

Biblioteca Elixir para a API da Iugu, pública no GitHub: nada de token, chave ou dado de conta real em código, teste ou doc. Só cliente HTTP: nenhum schema, contexto, worker ou rota. Quem liga o SDK a uma funcionalidade é o app que o consome.

## Comandos

```bash
mix deps.get
mix precommit      # compile --warnings-as-errors + format + credo --strict + test
```

## Regras

- Toda função pública devolve `{:ok, _}` ou `{:error, %Iugu.Error{}}`; o que a Iugu recusaria com 4xx e dá para conferir antes volta como `kind: :validation, status: nil`, sem ir à rede
- `Iugu.Client` é o único módulo que fala HTTP. Rota nova é função num módulo de recurso mais um `defdelegate` na fachada `Iugu`
- HTTP nos testes só por `Req.Test` (`config :iugu_sdk, req_options: [plug: {Req.Test, Iugu.Client}]`), nunca Mimic. Rota assinada confere a assinatura com `Iugu.TestHelpers.assert_signed/4`
- Teste é jornada, um por fluxo, com nome em inglês no estilo BDD; testes de um módulo ficam no arquivo de teste dele
- `@moduledoc`, `@doc` e comentários em pt-BR; identificadores em inglês. Comentário só para o porquê. Nunca use travessão. Comentário que começa com "Todo" dispara o `TagTODO` do Credo: escreva "Cada", "A tabela inteira"
- Cada moduledoc de recurso termina com "O que não está confirmado": o que a documentação da Iugu não diz e só uma conta real prova. Ao confirmar, atualize o moduledoc e o README
- Rota que move dinheiro sem `Idempotency-Key` documentada nunca repete (`retry: false`); a que aceita a chave liga o retry só com `:idempotency_key`
- Fonte da verdade é <https://dev.iugu.com> (índice em `/llms.txt`, cada página em `.md`). O SDK PHP oficial é v1 de 2024 e não cobre BaaS nem assinatura RSA
