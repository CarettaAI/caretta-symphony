defmodule Symphony.HTTPServerTest do
  use ExUnit.Case, async: true

  alias Symphony.Error
  alias Symphony.HTTPServer

  test "start raises a stable Symphony error when the port is already bound" do
    server = HTTPServer.start(%{}, port: 0)

    try do
      error =
        assert_raise Error, fn ->
          HTTPServer.start(%{}, port: server.bound_port)
        end

      assert error.code == :http_server_bind_failed
      assert error.message =~ "127.0.0.1:#{server.bound_port}"
      assert error.message =~ ":eaddrinuse"
    after
      HTTPServer.stop(server)
    end
  end
end
