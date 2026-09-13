defmodule Iugu.Params do
  @moduledoc """
  Ajudantes que todo recurso do SDK usa para montar corpo e query string e
  para recusar, antes de gastar a chamada, o que a Iugu recusaria com 4xx.

  Os recursos repetem os mesmos passos: omitir o que é `nil`, aceitar chave
  atom ou string, exigir campos, aceitar só um valor de uma lista e escrever
  data e hora no fuso da Iugu. Concentrá-los aqui faz uma correção no
  formato do `-03:00` ou na mensagem de campo ausente acontecer uma vez.

  A Iugu vive no horário de São Paulo: todo filtro de data e hora da
  documentação traz o deslocamento `-03:00`, e o dia dos extratos fecha à
  meia-noite local. `format_local_datetime/1` e `local_today/0` partem
  desse fuso.
  """

  alias Iugu.Error

  @time_zone "America/Sao_Paulo"

  @doc "Põe `value` em `map` sob `key`, a menos que seja `nil`."
  @spec put_present(map(), term(), term()) :: map()
  def put_present(map, _key, nil), do: map
  def put_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  Se `map` tem em `key` um valor que não é `nil`, `""` nem `[]`.

  Fora de um mapa a resposta é `false`, para que a checagem de um campo
  aninhado (`receiver.pix`) não estoure quando o chamador mandou outra coisa.
  """
  @spec present?(term(), term()) :: boolean()
  def present?(map, key) when is_map(map) do
    case Map.get(map, key) do
      nil -> false
      "" -> false
      [] -> false
      _value -> true
    end
  end

  def present?(_map, _key), do: false

  @doc "Converte as chaves de um mapa para string, sem descer nos valores."
  @spec stringify_keys(map()) :: %{optional(String.t()) => term()}
  def stringify_keys(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), value} end)
  end

  @doc """
  Resolve `key` (atom ou string) num dos campos de `fields`.

  Uma chave fora da lista é erro de programação, não dado do usuário, então
  levanta `ArgumentError` em vez de virar `{:error, _}`: a Iugu ignoraria o
  campo em silêncio ou responderia 400 por um nome que só existe no nosso
  código. `resource` entra na mensagem ("campo de fatura desconhecido").
  """
  @spec field!(atom() | String.t(), [atom()], String.t()) :: atom()
  def field!(key, fields, resource) when is_atom(key) do
    if key in fields, do: key, else: raise_unknown_field(key, fields, resource)
  end

  def field!(key, fields, resource) when is_binary(key) do
    case Enum.find(fields, &(Atom.to_string(&1) == key)) do
      nil -> raise_unknown_field(key, fields, resource)
      field -> field
    end
  end

  def field!(key, fields, resource), do: raise_unknown_field(key, fields, resource)

  @doc "Exige cada chave de `keys` presente em `map` (veja `present?/2`)."
  @spec validate_present(map(), [term()], String.t() | nil) :: :ok | {:error, Error.t()}
  def validate_present(map, keys, path) do
    case Enum.reject(keys, &present?(map, &1)) do
      [] ->
        :ok

      missing ->
        {:error,
         Error.validation("Campos obrigatórios ausentes: #{Enum.join(missing, ", ")}.", path)}
    end
  end

  @doc "Aceita `nil` (campo não enviado) ou um valor de `allowed`."
  @spec validate_member(term(), [term()], String.t(), String.t() | nil) ::
          :ok | {:error, Error.t()}
  def validate_member(value, allowed, field, path) do
    if is_nil(value) or value in allowed do
      :ok
    else
      {:error,
       Error.validation(
         "#{field} inválido: #{inspect(value)}. Use um de #{inspect(allowed)}.",
         path
       )}
    end
  end

  @doc "Aceita `nil` ou uma string de até `max_length` caracteres."
  @spec validate_length(String.t() | nil, pos_integer(), String.t(), String.t() | nil) ::
          :ok | {:error, Error.t()}
  def validate_length(nil, _max_length, _field, _path), do: :ok

  def validate_length(value, max_length, field, path) when is_binary(value) do
    if String.length(value) <= max_length do
      :ok
    else
      {:error,
       Error.validation("#{field} é muito longo (máximo: #{max_length} caracteres).", path)}
    end
  end

  @doc """
  Data e hora como a Iugu espera nos filtros de listagem.

  Um `DateTime` vai para o horário de São Paulo com precisão de segundos
  (`2026-09-03T10:16:34-03:00`), porque a documentação só mostra o filtro
  com o deslocamento `-03:00`. Um `Date` vira `AAAA-MM-DD` e uma string
  passa como veio, para quem já tem o valor no formato da Iugu.
  """
  @spec format_local_datetime(DateTime.t() | Date.t() | String.t() | nil) :: String.t() | nil
  def format_local_datetime(nil), do: nil

  def format_local_datetime(%DateTime{} = datetime) do
    # Base explícita para a lib não depender de `:time_zone_database` global
    # do app que a usa.
    datetime
    |> DateTime.shift_zone!(@time_zone, Tzdata.TimeZoneDatabase)
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  def format_local_datetime(%Date{} = date), do: Date.to_iso8601(date)
  def format_local_datetime(value) when is_binary(value), do: value

  @doc "`Date` em `AAAA-MM-DD`; string passa como veio."
  @spec format_date(Date.t() | String.t() | nil) :: String.t() | nil
  def format_date(nil), do: nil
  def format_date(%Date{} = date), do: Date.to_iso8601(date)
  def format_date(value) when is_binary(value), do: value

  @doc """
  O dia de hoje no fuso da Iugu.

  `Date.utc_today/0` adianta um dia entre 21h e meia-noite em São Paulo, e
  nessa janela uma regra como "só até ontem" deixaria passar o dia corrente.
  """
  @spec local_today() :: Date.t()
  def local_today do
    @time_zone
    |> DateTime.now!(Tzdata.TimeZoneDatabase)
    |> DateTime.to_date()
  end

  defp raise_unknown_field(key, fields, resource) do
    raise ArgumentError,
          "campo de #{resource} desconhecido: #{inspect(key)}. Os campos aceitos são #{inspect(fields)}."
  end
end
