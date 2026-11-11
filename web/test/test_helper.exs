{:ok, _} = Annuart.RpcStub.start_link()
ExUnit.start()
Ecto.Adapters.SQL.Sandbox.mode(Annuart.Repo, :manual)
