defmodule Iugu.TestHelpers do
  @moduledoc """
  Ajudantes dos testes do SDK da Iugu: o stub do `Req.Test` que entrega o
  corpo cru, as asserções sobre autenticação e assinatura RSA e um par de
  chaves gerado na hora para conferir a assinatura com a pública.
  """

  import ExUnit.Assertions

  @doc "Espera uma requisição e entrega a `conn` com o corpo JSON decodificado."
  def expect_request(fun) do
    expect_request_raw(fn conn, raw_body -> fun.(conn, Jason.decode!(raw_body)) end)
  end

  @doc """
  Espera uma requisição e entrega a `conn` com o corpo como bytes.

  É o que uma asserção de assinatura precisa: o documento assinado cobre o
  corpo exato que saiu, não o mapa que o gerou.
  """
  def expect_request_raw(fun) do
    Req.Test.expect(Iugu.Client, fn conn ->
      {:ok, raw_body, conn} = Plug.Conn.read_body(conn)

      fun.(conn, raw_body)
    end)
  end

  @doc "HTTP Basic com o token como usuário e senha vazia."
  def assert_basic(conn, api_token) do
    assert Plug.Conn.get_req_header(conn, "authorization") == [
             "Basic " <> Base.encode64(api_token <> ":")
           ]
  end

  @doc "Nenhum header de assinatura RSA saiu na requisição."
  def assert_unsigned(conn) do
    assert Plug.Conn.get_req_header(conn, "signature") == []
    assert Plug.Conn.get_req_header(conn, "request-time") == []
  end

  @doc """
  Reconstrói o documento de três linhas que a Iugu verifica do lado dela
  (método e caminho com `/v1`, token da requisição e `Request-Time`, corpo
  cru) e confere a assinatura com a chave pública.
  """
  def assert_signed(conn, raw_body, public_key, api_token) do
    [request_time] = Plug.Conn.get_req_header(conn, "request-time")
    ["signature=" <> encoded_signature] = Plug.Conn.get_req_header(conn, "signature")

    content = "#{conn.method}|#{conn.request_path}\n#{api_token}|#{request_time}\n#{raw_body}"

    assert :public_key.verify(content, :sha256, Base.decode64!(encoded_signature), public_key)
  end

  @doc """
  Stub que recusa a conexão em toda tentativa e avisa o teste a cada uma,
  para contar quantas vezes o SDK repetiu.
  """
  def stub_counting_transport_error do
    test_pid = self()

    Req.Test.stub(Iugu.Client, fn conn ->
      send(test_pid, :iugu_attempt)
      Req.Test.transport_error(conn, :econnrefused)
    end)
  end

  @doc "Quantas tentativas o stub registrou, consumindo os avisos."
  def attempts, do: count_attempts(0)

  @doc """
  Quantas tentativas já foram registradas, sem consumir os avisos.

  Serve para o stub distinguir a primeira chamada da repetição enquanto o
  teste ainda conta o total no fim.
  """
  def attempts_so_far do
    {:messages, messages} = Process.info(self(), :messages)

    Enum.count(messages, &(&1 == :iugu_attempt))
  end

  @doc """
  Par de chaves RSA de 2048 bits: o PEM privado que o SDK assina e a pública
  com que o teste verifica. O registro `RSAPrivateKey` carrega o módulo e o
  expoente público nas posições 2 e 3.
  """
  def generate_key_pair do
    private_key = :public_key.generate_key({:rsa, 2048, 65_537})
    pem = :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, private_key)])

    {pem, {:RSAPublicKey, elem(private_key, 2), elem(private_key, 3)}}
  end

  defp count_attempts(count) do
    receive do
      :iugu_attempt -> count_attempts(count + 1)
    after
      0 -> count
    end
  end
end
