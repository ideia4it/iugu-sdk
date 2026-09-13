defmodule Iugu.PixKey do
  @moduledoc """
  Chaves Pix da conta Iugu: para onde um depósito por Pix é enviado.

  A conta Iugu recebe Pix pela chave que a Iugu registra no DICT em nome
  dela (uma chave aleatória, `evp`) ou por uma chave que o titular traz
  (e-mail, telefone, CPF/CNPJ). Este módulo só lê; cadastrar, portar e
  reivindicar chave é pelo painel, e a mudança chega pelo webhook
  `pix_key.status_changed`. Para ativar ou desativar o Pix como meio de
  recebimento da conta, veja `Iugu.Account.set_pix/2`.

  ## Duas rotas, duas visões

    * `registered/1` (`GET /v1/pix/keys`): as chaves como estão no DICT,
      com `key`, `type` e `start_date`. É o que se mostra ao cliente para
      ele depositar
    * `list/1` (`GET /v1/bank_account_pix_keys`): "todas as chaves PIX
      atreladas à conta, ativas, processando e aguardando um pedido de
      custódia solicitado ou enviado ou aguardando resolução", com `status`.
      É o que se olha para saber se a chave já vale

  ## Só produção

  As duas rotas "funcionam apenas em ambiente de Produção": com
  `test_api_token` a Iugu responde 401 `Apenas disponível para o ambiente
  produção`, que o SDK devolve como `kind: :unauthorized`. Autenticam com o
  `live_api_token` da conta em `api_token:`, sem assinatura RSA.

  ## O que não está confirmado

    * os valores de `status` em `list/1` além de `active` (o texto fala em
      processando e custódia; os nomes não aparecem) e de `type` em
      `registered/1` além de `evp`
    * se `registered/1` devolve mais de uma chave quando o titular trouxe a
      sua, e a forma da resposta sem chave (lista vazia ou 404)
  """

  alias Iugu.Client
  alias Iugu.Error
  alias Iugu.Response

  @registered_path "/v1/pix/keys"
  @path "/v1/bank_account_pix_keys"

  @type registered :: %{
          key: String.t() | nil,
          type: String.t() | nil,
          name: String.t() | nil,
          start_date: String.t() | nil,
          created_at: String.t() | nil,
          body: map()
        }

  @type t :: %{
          id: String.t() | nil,
          key: String.t() | nil,
          type: String.t() | nil,
          status: String.t() | nil,
          created_at: String.t() | nil,
          body: map()
        }

  @doc """
  As chaves Pix da conta como estão no DICT. Veja o moduledoc.

  `GET /v1/pix/keys`, `live_api_token` da conta, só produção. `name` é o
  nome do titular que aparece para quem paga.
  """
  @spec registered(keyword()) :: {:ok, [registered()]} | {:error, Error.t()}
  def registered(opts \\ []) do
    with {:ok, body} <- Client.get(@registered_path, opts) do
      {:ok, body |> Response.items() |> Enum.map(&normalize_registered/1)}
    end
  end

  @doc """
  Todas as chaves Pix da conta, com o `status` de cada uma. Veja o moduledoc.

  `GET /v1/bank_account_pix_keys`, `live_api_token` da conta, só produção.
  """
  @spec list(keyword()) :: {:ok, [t()]} | {:error, Error.t()}
  def list(opts \\ []) do
    with {:ok, body} <- Client.get(@path, opts) do
      {:ok, body |> Response.items(["pix_keys"]) |> Enum.map(&normalize/1)}
    end
  end

  defp normalize_registered(body) when is_map(body) do
    %{
      key: Map.get(body, "key"),
      type: Map.get(body, "type"),
      name: Map.get(body, "name"),
      start_date: Map.get(body, "start_date"),
      created_at: Map.get(body, "created_at"),
      body: body
    }
  end

  defp normalize(body) when is_map(body) do
    %{
      id: Map.get(body, "id"),
      key: Map.get(body, "pix_key"),
      type: Map.get(body, "pix_key_type"),
      status: Map.get(body, "status"),
      created_at: Map.get(body, "created_at"),
      body: body
    }
  end
end
