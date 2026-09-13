import Config

# A Iugu não tem host de sandbox: produção e teste usam a mesma base_url, e é
# o token que escolhe o ambiente (live_api_token ou test_api_token, ambos
# criados no painel Alia).
#
# Quem usa a lib fornece o token e as chaves no runtime.exs do próprio app:
#
#     config :iugu_sdk,
#       api_token: System.get_env("IUGU_API_TOKEN"),
#       signature_private_key: System.get_env("IUGU_SIGNATURE_PRIVATE_KEY"),
#       signature_token_id: System.get_env("IUGU_SIGNATURE_TOKEN_ID"),
#       webhook_authorization: System.get_env("IUGU_WEBHOOK_AUTHORIZATION")
config :iugu_sdk,
  base_url: "https://api.iugu.com",
  api_token: nil,
  signature_private_key: nil,
  signature_token_id: nil,
  webhook_authorization: nil,
  receive_timeout: :timer.seconds(30)

import_config "#{config_env()}.exs"
