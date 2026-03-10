## Slice Protocol

### Deployment
0. Get private key 
```bash 
iota keytool import "<words>" <key_scheme>
iota keytool list
iota keytool export <address>
```

1. Run a local IOTA network
Run a local node (ref: [Local Development](https://docs.iota.org/developer/getting-started/local-network))
Create a IOTA client
```bash 
iota client new-env --alias local --rpc http://127.0.0.1:9000
iota client switch --env local
iota client active-address
iota client faucet
```

```bash 
RUST_LOG="off,iota_node=info" iota start --force-regenesis --with-faucet
```

[Local Explorer](https://explorer.iota.org/?network=http%3A%2F%2F127.0.0.1%3A9000)

2. Deploy the protocol
Deploy protocol
```bash
chmod +x ./scripts/deploy.sh
./scripts/deploy.sh [testnet|mainnet|localnet]
```
5. After publishing
  1. pool_contract::set_contracts
  2. pool_contract::initialise_pool
  3. tranche_factory::bootstrap
  4. tranche_factory::create_tranches



