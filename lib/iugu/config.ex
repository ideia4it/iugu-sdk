defmodule Iugu.Config do
  @moduledoc """
  Leitura da configuração da Iugu (`config :iugu_sdk`).

  Ponto único que traduz config em valor, para que nenhum módulo do SDK chame
  `Application.get_env/3` por conta própria.

  O token é lido com `api_token!/0`, que levanta em vez de devolver `nil`: a
  Iugu responde 401 sem corpo documentado, e um 401 é indistinguível de token
  pendente de aprovação ou de IP bloqueado. Falhar aqui aponta para a
  configuração, não para a Iugu.

  A Iugu **não tem host de sandbox**: produção e teste usam a mesma
  `base_url`, e é o token (`live_api_token` ou `test_api_token`) que escolhe o
  ambiente. Por isso não há `base_url` por ambiente aqui.
  """

  @doc """
  URL base da API, sem o prefixo `/v1`.

  É sempre `https://api.iugu.com`. O prefixo `/v1` fica no caminho de cada
  recurso porque ele faz parte da string assinada no RSA
  (`POST|/v1/marketplace/create_account`), e escondê-lo na `base_url` faria a
  assinatura sair errada sem nenhum aviso.
  """
  def base_url, do: get(:base_url) || "https://api.iugu.com"

  @doc """
  Token da conta mestre, enviado em `Authorization: Basic Base64("TOKEN:")`.

  Em produção é o `live_api_token`; para o modo de teste da Iugu basta trocar
  por um `test_api_token`, no mesmo host.
  """
  def api_token! do
    fetch!(:api_token) ||
      raise """
      Token de API da Iugu não configurado.

      Defina a variável de ambiente IUGU_API_TOKEN (produção) ou
      `config :iugu_sdk, api_token: "..."` (dev). O token sai do painel
      Alia em Configurações > Integrações API > Novo, e precisa da aprovação de
      um administrador da conta antes de funcionar.
      """
  end

  @doc """
  Chave privada RSA em PEM, usada para assinar as rotas que movimentam
  dinheiro, criam subconta ou mexem em tokens.

  Opcional: só as chamadas com `sign: true` precisam dela. A chave pública
  correspondente é colada no painel Alia ao criar um token de produção.
  """
  def signature_private_key, do: get(:signature_private_key)

  @doc "Como `signature_private_key/0`, mas levanta quando a chave não existe."
  def signature_private_key! do
    signature_private_key() ||
      raise """
      Chave privada RSA da Iugu não configurada.

      Esta rota exige a Assinatura RSA. Defina a variável de ambiente
      IUGU_SIGNATURE_PRIVATE_KEY com o PEM da chave privada (produção) ou
      `config :iugu_sdk, signature_private_key: "..."` (dev). Gere o
      par com `openssl genrsa -out private.pem 2048` e cole a chave pública no
      painel Alia ao criar o token de produção.
      """
  end

  @doc """
  Id do token cuja chave pública está cadastrada no painel, enviado no header
  `X-Signature-Token-Id`.

  Opcional. Sem ele a Iugu "mantém o comportamento atual", mas a documentação
  recomenda mandar sempre que a conta tiver mais de um token LIVE com RSA.
  """
  def signature_token_id, do: get(:signature_token_id)

  @doc """
  Valor que a Iugu devolve no header `Authorization` ao chamar a nossa URL de
  webhook. É o que cadastramos no campo `authorization` do gatilho.

  Opcional: sem ele `Iugu.Webhook.Event.authorized?/2` recusa toda
  entrega, porque um webhook sem segredo configurado não tem como ser
  conferido.
  """
  def webhook_authorization, do: get(:webhook_authorization)

  @doc "Timeout de resposta aplicado a todas as chamadas."
  def receive_timeout, do: get(:receive_timeout) || :timer.seconds(30)

  defp fetch!(key), do: Application.fetch_env!(:iugu_sdk, key)

  defp get(key), do: Application.get_env(:iugu_sdk, key)
end
