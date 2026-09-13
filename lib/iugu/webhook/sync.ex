defmodule Iugu.Webhook.Sync do
  @moduledoc """
  Cadastra de uma vez todos os gatilhos de uma URL na Iugu.

  Um gatilho escuta um evento; assinar vários é criar um gatilho por evento.
  Fazer isso pelo painel Alia é demorado, dá para esquecer um e não sobrevive
  à troca de ambiente. Este módulo faz o laço a partir da lista que a própria
  conta publica em `GET /v1/web_hooks/supported_events`.

  ## É idempotente onde a Iugu não é

  A Iugu aceita gatilho duplicado ("limitação de configuração de 20
  gatilhos, sendo iguais ou não") e não tem chave de idempotência: dois
  `create/2` iguais são dois gatilhos, cada um entregando o mesmo evento.
  `sync/2` lista o que já existe na URL antes de criar e só cria o que falta.
  A chave de comparação é `{url, event}`; rodar duas vezes seguidas devolve
  tudo em `:unchanged`.

  Como a Iugu tem rota de alteração, o segredo também é reconciliado: um
  gatilho da URL cujo `authorization` difere do desejado é atualizado por
  `PUT` e volta em `:updated`. Um gatilho com `active: false` volta em
  `:inactive` e **não** é mexido, porque nenhum parâmetro documentado o
  reativa; isso é decisão de quem opera, pelo painel.

  Gatilhos repetidos para o mesmo `{url, event}` voltam em `:duplicated`
  (todos menos o primeiro); com `prune: true` eles são removidos, junto com
  os gatilhos da URL cujo evento saiu da lista. Sem `prune`, apontar o
  ambiente para outra URL deixaria os antigos ativos e a Iugu entregaria o
  mesmo evento duas vezes.

  ## O limite de 20

  A conta inteira cabe em 20 gatilhos, os de outras URLs incluídos, e a
  lista de eventos passa de quarenta. Assinar tudo evento a evento não
  cabe: `sync/2` recusa com `Iugu.Error` de validação, **antes de
  escrever qualquer coisa**, um plano que deixaria a conta acima de
  `:max_triggers` (padrão 20). As saídas são `only:` com os eventos que
  interessam ou `events: ["all"]`, que assina tudo com um gatilho só e
  despacha pelo nome em `Iugu.Webhook.Event`. A tabela de erros
  fala em 30; se a conta aceitar, passe `max_triggers: 30`.

  ## Sem ping e sem limite de requisições documentado

  A Iugu não dispara chamada de teste ao criar o gatilho, e não documenta
  limite de requisições para estas rotas fora dos 50 por minuto do modo de
  teste. `:request_interval_ms` (padrão 150 ms) espaça as escritas; em teste,
  passe `0`.

  ## Exemplo

      iex> Iugu.Webhook.Sync.sync("https://app.example.com/v1/webhooks/iugu",
      ...>   only: ["invoice.status_changed", "referrals.verification"],
      ...>   dry_run: true
      ...> )

  Comece sempre por `dry_run: true`: ele monta o plano sem escrever nada.
  """

  alias Iugu.Config
  alias Iugu.Error
  alias Iugu.Webhook

  require Logger

  @default_interval_ms 150
  @default_max_triggers 20

  @type entry :: %{event: String.t(), id: String.t() | nil}

  @type report :: %{
          url: String.t(),
          dry_run: boolean(),
          created: [entry()],
          updated: [entry()],
          unchanged: [entry()],
          inactive: [entry()],
          duplicated: [entry()],
          deleted: [entry()],
          failed: [%{event: String.t(), error: Exception.t()}]
        }

  @doc """
  Sincroniza os gatilhos de `url` com a lista de eventos desejada.

  Opções:

    * `:events` - eventos a assinar. Padrão: o que
      `Iugu.Webhook.list_events/1` devolver, **menos `"all"`**,
      porque `all` mais os eventos um a um entregaria tudo em dobro. Se a
      chamada falhar, o sync falha junto, em vez de cair numa lista embutida
      que pode estar velha. Para trabalhar offline, passe
      `Iugu.Webhook.events()`; para um gatilho só, `["all"]`
    * `:only` - restringe a esses eventos
    * `:except` - remove esses eventos
    * `:authorization` - segredo que a Iugu vai devolver no header
      `Authorization` das chamadas para a nossa URL. Padrão:
      `config :iugu_sdk, webhook_authorization:`. Com valor, gatilhos
      existentes com outro segredo são atualizados; `nil` não mexe em nada
    * `:prune` - remove gatilhos duplicados e os da URL cujo evento não está
      na lista. Padrão `false`
    * `:max_triggers` - teto de gatilhos da conta depois do plano. Padrão
      #{@default_max_triggers}
    * `:dry_run` - monta o relatório sem escrever. Padrão `false`
    * `:request_interval_ms` - pausa entre escritas. Padrão #{@default_interval_ms}

  Todas as outras opções vão para `Iugu.Client` (`:api_token` para
  sincronizar a URL numa subconta, por exemplo).

  Devolve `{:ok, report}` mesmo com escritas individuais falhando: elas vão
  em `:failed`, com o erro de cada uma. Devolve `{:error, _}` quando o plano
  não pôde ser montado (listar eventos ou gatilhos falhou) ou quando ele
  estouraria `:max_triggers`.
  """
  @spec sync(String.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def sync(url, opts \\ []) when is_binary(url) do
    {sync_opts, req_opts} = split_opts(opts)

    with {:ok, wanted} <- wanted_events(sync_opts, req_opts),
         {:ok, all_triggers} <- Webhook.list(req_opts) do
      plan = build_plan(url, wanted, all_triggers, sync_opts)

      with :ok <- check_capacity(plan, all_triggers, sync_opts) do
        {:ok, apply_plan(plan, sync_opts, req_opts)}
      end
    end
  end

  @doc """
  Remove todos os gatilhos de uma URL, qualquer que seja o evento.

  Serve para desligar a integração de um ambiente sem caçar id por id no
  painel. Como `sync/2`, respeita `:dry_run`. Gatilhos de outras URLs da
  conta não são tocados.
  """
  @spec remove_all(String.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def remove_all(url, opts \\ []) when is_binary(url) do
    {sync_opts, req_opts} = split_opts(opts)

    with {:ok, all_triggers} <- Webhook.list(req_opts) do
      plan = build_plan(url, [], all_triggers, Keyword.put(sync_opts, :prune, true))

      {:ok, apply_plan(plan, sync_opts, req_opts)}
    end
  end

  defp split_opts(opts) do
    Keyword.split(opts, [
      :events,
      :only,
      :except,
      :authorization,
      :prune,
      :max_triggers,
      :dry_run,
      :request_interval_ms
    ])
  end

  defp wanted_events(sync_opts, req_opts) do
    with {:ok, events} <- resolve_events(Keyword.get(sync_opts, :events), req_opts) do
      {:ok, events |> filter_only(sync_opts) |> filter_except(sync_opts) |> Enum.uniq()}
    end
  end

  # "all" junto com os eventos individuais entregaria tudo duas vezes, então a
  # lista padrão o descarta; quem quer o gatilho único pede explicitamente.
  defp resolve_events(nil, req_opts) do
    with {:ok, events} <- Webhook.list_events(req_opts) do
      {:ok, events -- ["all"]}
    end
  end

  defp resolve_events(events, _req_opts) when is_list(events), do: {:ok, events}

  defp filter_only(events, sync_opts) do
    case Keyword.get(sync_opts, :only) do
      nil -> events
      only -> Enum.filter(events, &(&1 in List.wrap(only)))
    end
  end

  defp filter_except(events, sync_opts) do
    case Keyword.get(sync_opts, :except) do
      nil -> events
      except -> Enum.reject(events, &(&1 in List.wrap(except)))
    end
  end

  # A API lista a conta inteira e não tem filtro por url, então a comparação de
  # url é local: só gatilhos apontando para o nosso endereço são tocados.
  defp build_plan(url, wanted, all_triggers, sync_opts) do
    existing = Enum.filter(all_triggers, &(&1.url == url))
    {first_by_event, duplicated} = split_duplicates(existing)
    wanted_authorization = authorization(sync_opts)
    prune = Keyword.get(sync_opts, :prune, false)

    present = Enum.filter(wanted, &Map.has_key?(first_by_event, &1))
    missing = Enum.reject(wanted, &Map.has_key?(first_by_event, &1))

    {inactive, active} = Enum.split_with(present, &(first_by_event[&1].active == false))

    {to_update, unchanged} =
      Enum.split_with(active, &needs_authorization?(first_by_event[&1], wanted_authorization))

    extra =
      first_by_event
      |> Map.drop(wanted)
      |> Map.values()

    %{
      url: url,
      wanted_authorization: wanted_authorization,
      missing: missing,
      to_update: Enum.map(to_update, &first_by_event[&1]),
      unchanged: Enum.map(unchanged, &first_by_event[&1]),
      inactive: Enum.map(inactive, &first_by_event[&1]),
      duplicated: duplicated,
      to_delete: if(prune, do: extra ++ duplicated, else: [])
    }
  end

  # A Iugu mantém todas as duplicatas; a primeira vista para um evento é a que
  # a sincronização considera, as demais são reportadas (e removidas quando
  # pedido).
  defp split_duplicates(existing) do
    Enum.reduce(existing, {%{}, []}, fn trigger, {first_by_event, duplicated} ->
      if Map.has_key?(first_by_event, trigger.event) do
        {first_by_event, duplicated ++ [trigger]}
      else
        {Map.put(first_by_event, trigger.event, trigger), duplicated}
      end
    end)
  end

  defp needs_authorization?(_trigger, nil), do: false
  defp needs_authorization?(trigger, wanted), do: trigger.authorization != wanted

  defp check_capacity(plan, all_triggers, sync_opts) do
    max_triggers = Keyword.get(sync_opts, :max_triggers, @default_max_triggers)
    after_plan = length(all_triggers) - length(plan.to_delete) + length(plan.missing)

    if after_plan <= max_triggers do
      :ok
    else
      {:error,
       Error.validation(
         "o plano deixaria a conta com #{after_plan} gatilhos, acima do limite de #{max_triggers}. " <>
           "Restrinja com only:, assine tudo com events: [\"all\"] ou remova gatilhos de outras URLs.",
         "/v1/web_hooks"
       )}
    end
  end

  defp apply_plan(plan, sync_opts, req_opts) do
    dry_run = Keyword.get(sync_opts, :dry_run, false)

    {created, create_failures} = create_missing(plan, sync_opts, req_opts, dry_run)
    {updated, update_failures} = update_authorization(plan, sync_opts, req_opts, dry_run)
    {deleted, delete_failures} = delete_extra(plan, sync_opts, req_opts, dry_run)

    %{
      url: plan.url,
      dry_run: dry_run,
      created: created,
      updated: updated,
      unchanged: Enum.map(plan.unchanged, &entry/1),
      inactive: Enum.map(plan.inactive, &entry/1),
      duplicated: Enum.map(plan.duplicated, &entry/1),
      deleted: deleted,
      failed: create_failures ++ update_failures ++ delete_failures
    }
  end

  defp create_missing(%{missing: []}, _sync_opts, _req_opts, _dry_run), do: {[], []}

  defp create_missing(plan, _sync_opts, _req_opts, true) do
    Logger.info("iugu: #{length(plan.missing)} gatilhos a criar em #{plan.url}")

    {Enum.map(plan.missing, &%{event: &1, id: nil}), []}
  end

  defp create_missing(plan, sync_opts, req_opts, false) do
    plan.missing
    |> Enum.map(fn event ->
      throttle(sync_opts)

      attrs =
        %{event: event, url: plan.url}
        |> put_present(:authorization, plan.wanted_authorization)

      case Webhook.create(attrs, req_opts) do
        {:ok, trigger} -> {:ok, %{event: event, id: trigger.id}}
        {:error, error} -> {:error, %{event: event, error: error}}
      end
    end)
    |> split_results()
  end

  defp update_authorization(%{to_update: []}, _sync_opts, _req_opts, _dry_run), do: {[], []}

  defp update_authorization(plan, _sync_opts, _req_opts, true) do
    {Enum.map(plan.to_update, &entry/1), []}
  end

  defp update_authorization(plan, sync_opts, req_opts, false) do
    plan.to_update
    |> Enum.map(fn trigger ->
      throttle(sync_opts)

      case Webhook.update(trigger.id, %{authorization: plan.wanted_authorization}, req_opts) do
        {:ok, _updated} -> {:ok, entry(trigger)}
        {:error, error} -> {:error, %{event: trigger.event, error: error}}
      end
    end)
    |> split_results()
  end

  defp delete_extra(%{to_delete: []}, _sync_opts, _req_opts, _dry_run), do: {[], []}

  defp delete_extra(plan, _sync_opts, _req_opts, true) do
    {Enum.map(plan.to_delete, &entry/1), []}
  end

  defp delete_extra(plan, sync_opts, req_opts, false) do
    plan.to_delete
    |> Enum.map(fn trigger ->
      throttle(sync_opts)
      delete_one(trigger, req_opts)
    end)
    |> split_results()
  end

  defp delete_one(%{id: nil, event: event}, _req_opts) do
    {:error, %{event: event, error: %ArgumentError{message: "gatilho sem id na listagem"}}}
  end

  defp delete_one(trigger, req_opts) do
    case Webhook.delete(trigger.id, req_opts) do
      {:ok, _deleted} -> {:ok, entry(trigger)}
      {:error, error} -> {:error, %{event: trigger.event, error: error}}
    end
  end

  defp split_results(results) do
    {ok, error} = Enum.split_with(results, &match?({:ok, _entry}, &1))
    {Enum.map(ok, &elem(&1, 1)), Enum.map(error, &elem(&1, 1))}
  end

  defp entry(trigger), do: %{event: trigger.event, id: trigger.id}

  defp authorization(sync_opts) do
    Keyword.get_lazy(sync_opts, :authorization, &Config.webhook_authorization/0)
  end

  defp throttle(sync_opts) do
    case Keyword.get(sync_opts, :request_interval_ms, @default_interval_ms) do
      interval when is_integer(interval) and interval > 0 -> Process.sleep(interval)
      _zero_or_invalid -> :ok
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
