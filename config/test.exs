import Config

# Sem chave RSA aqui de propósito: os testes que assinam geram um par de
# chaves em memória e passam a privada por opção, o que também cobre o fluxo
# whitelabel (chave da conta mestre com token de subconta).
config :iugu_sdk,
  api_token: "iugu-test-token",
  webhook_authorization: "iugu-test-webhook-authorization",
  req_options: [plug: {Req.Test, Iugu.Client}]
