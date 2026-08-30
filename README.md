# Gero Node Monitor

Lightweight monitoring agent for Cardano block producer nodes. Exposes a simple HTTP API that the Gero Wallet SPO dashboard polls for node health, KES status, and leader schedule.

## Quick Install

```bash
curl -sSL https://raw.githubusercontent.com/Gero-Labs/gero-node-monitor/main/install.sh | bash
```

Or manual:
```bash
git clone https://github.com/Gero-Labs/gero-node-monitor.git
cd gero-node-monitor
chmod +x gero-node-monitor.sh
./gero-node-monitor.sh --config
```

## Requirements

- **cardano-node** running on the same machine
- **cncli** installed (for leader schedule calculation)
- **jq** installed
- **socat** or **netcat** for socket queries
- Access to the node socket (usually `$CARDANO_NODE_SOCKET_PATH`)
- Access to `vrf.skey` (for leader schedule)

## Configuration

On first run with `--config`, the agent creates `~/.gero-node-monitor/config.json`:

```json
{
  "port": 12798,
  "host": "0.0.0.0",
  "cardanoNodeSocket": "/opt/cardano/cnode/sockets/node.socket",
  "cardanoCliPath": "/usr/local/bin/cardano-cli",
  "cncliPath": "/usr/local/bin/cncli",
  "vrfSkeyPath": "/opt/cardano/cnode/priv/pool/vrf.skey",
  "poolId": "pool1...",
  "genesisFile": "/opt/cardano/cnode/files/shelley-genesis.json",
  "byronGenesisFile": "/opt/cardano/cnode/files/byron-genesis.json",
  "network": "mainnet",
  "dbPath": "/opt/cardano/cnode/guild-db/cncli/cncli.db",
  "allowedOrigins": ["*"],
  "tunnel": false,
  "authToken": "<generated at install time>"
}
```

### Config Fields

| Field | Description | Default |
|-------|-------------|---------|
| `port` | HTTP server port | `12798` |
| `host` | Bind address (`0.0.0.0` for all, `127.0.0.1` for local only) | `127.0.0.1` |
| `cardanoNodeSocket` | Path to `node.socket` | Auto-detected from `$CARDANO_NODE_SOCKET_PATH` |
| `cardanoCliPath` | Path to `cardano-cli` binary | Auto-detected |
| `cncliPath` | Path to `cncli` binary | Auto-detected |
| `vrfSkeyPath` | Path to `vrf.skey` | Required for leader schedule |
| `poolId` | Pool ID (bech32) | Required |
| `genesisFile` | Shelley genesis JSON | Auto-detected from cntools paths |
| `byronGenesisFile` | Byron genesis JSON | Auto-detected |
| `network` | `mainnet` / `preprod` / `preview` | `mainnet` |
| `dbPath` | cncli SQLite database path | Auto-detected |
| `allowedOrigins` | CORS allowed origins | `["*"]` |
| `tunnel` | Publish a public `*.trycloudflare.com` URL for remote access | `false` |
| `allowedOrigins` | Not enforced — CORS is always `*`; `authToken` is the access control | — |
| `authToken` | Bearer token required on every request. Generated at install time. Mandatory when `tunnel` is `true` | generated |

## API Endpoints

### `GET /status`

Node health and metrics.

**Response:**
```json
{
  "blockHeight": 13196353,
  "slotNo": 182707368,
  "epoch": 620,
  "epochSlot": 307368,
  "epochSlotsRemaining": 124632,
  "kesRemaining": 287,
  "kesPeriod": 481,
  "kesExpiryEpoch": 635,
  "peers": 12,
  "peersIn": 8,
  "peersOut": 4,
  "memoryMb": 14200,
  "cpuPercent": 3.2,
  "mempoolTxs": 5,
  "mempoolBytes": 12400,
  "uptimeSeconds": 864000,
  "nodeVersion": "10.4.0",
  "syncProgress": 100.0,
  "timestamp": 1774273659
}
```

### `GET /leader-schedule?epoch=current|next`

Leader schedule calculated via cncli.

**Query Parameters:**
| Param | Values | Description |
|-------|--------|-------------|
| `epoch` | `current` (default), `next` | Which epoch to calculate |

**Response:**
```json
{
  "epoch": 620,
  "poolId": "pool12yscr8j3zs34ewxrwlk0p2w5uvgcnrzywpp78ddjsj8kxd530f9",
  "slots": [
    {
      "slot": 182534400,
      "slotInEpoch": 134400,
      "timestamp": 1774100400,
      "produced": true
    },
    {
      "slot": 182598000,
      "slotInEpoch": 198000,
      "timestamp": 1774164000,
      "produced": false
    },
    {
      "slot": 182712000,
      "slotInEpoch": 312000,
      "timestamp": 1774278000,
      "produced": null
    }
  ],
  "totalSlots": 3,
  "producedCount": 1,
  "missedCount": 1,
  "pendingCount": 1,
  "calculatedAt": 1774273659
}
```

`produced` values:
- `true` — block was produced successfully
- `false` — slot was assigned but block was not found on chain (missed/ghosted/stolen)
- `null` — slot is in the future (not yet due)

### `GET /blocks?epoch=620&limit=50`

Recent blocks produced by the pool.

**Response:**
```json
{
  "epoch": 620,
  "blocks": [
    {
      "blockNo": 13196200,
      "slotNo": 182600000,
      "slotInEpoch": 200000,
      "blockHash": "abc123...",
      "blockSize": 1234,
      "txCount": 5,
      "timestamp": 1774166000
    }
  ]
}
```

### `GET /rewards?epochs=10`

Pool rewards history.

**Response:**
```json
{
  "rewards": [
    {
      "epoch": 620,
      "poolRewards": "1290968354",
      "delegatorRewards": "4560000000",
      "activeStake": "983000000000",
      "blocksProduced": 3,
      "blocksExpected": 2.8,
      "luck": 107.1
    }
  ]
}
```

### `GET /health`

Simple health check.

**Response:**
```json
{
  "status": "ok",
  "version": "1.0.0",
  "nodeConnected": true
}
```

## Security

This agent serves your block producer's `/leader-schedule` — the slots your pool
is due to mint. Treat access to it as sensitive: advance knowledge of those slots
is what someone would need to time an attack against your producer.

### Network access
Binds to `127.0.0.1` by default, so it is local-only until you opt in to remote
access.

Setting `"tunnel": true` publishes the agent on a public `*.trycloudflare.com`
URL and registers that URL with the Gero backend for wallet auto-discovery.
Note that inbound firewall rules do not constrain this — `cloudflared` makes an
outbound connection. The tunnel therefore requires `authToken` to be set; the
agent refuses to start otherwise.

For remote access without the tunnel, keep `"tunnel": false` and use a reverse
proxy with HTTPS, an SSH tunnel, or WireGuard.

### Authentication
`authToken` is generated at install time and required on every request as
`Authorization: Bearer <token>`. The comparison is constant-time.

Leaving it empty disables the check — acceptable only for a local-only instance
(`"tunnel": false` and `host` on loopback), never for anything reachable off the
machine.

> **Upgrading from an earlier version?** Older releases shipped `"authToken": ""`
> with `tunnel` defaulting to **on**, and skipped the auth check entirely when the
> token was empty — so those instances published every endpoint publicly with no
> authentication. If you ran one, assume the URL was reachable, set an `authToken`,
> and restart. The old tunnel URL stops working once the agent restarts.

> **Wallet support:** sending the token requires Gero Wallet with
> [gerowallet#1014](https://github.com/Gero-Labs/gerowallet/pull/1014). Older
> builds cannot authenticate, so a token-protected agent is unreachable from them.

### CORS
By default allows all origins (`*`). Restrict to your extension ID:
```json
{
  "allowedOrigins": ["chrome-extension://your-extension-id"]
}
```

## Running as a Service

### systemd
```bash
sudo cp gero-node-monitor.service /etc/systemd/system/
sudo systemctl enable gero-node-monitor
sudo systemctl start gero-node-monitor
```

### Docker
```bash
docker run -d \
  --name gero-node-monitor \
  -p 12798:12798 \
  -v /opt/cardano/cnode:/cnode:ro \
  -v /run/cardano-node:/run/cardano-node:ro \
  gerolabs/gero-node-monitor
```

## Implementation Notes

### How the Leader Schedule Works

1. Agent receives `GET /leader-schedule?epoch=current`
2. Runs `cncli leaderlog` with the pool's VRF key:
   ```bash
   cncli leaderlog \
     --db $DB_PATH \
     --pool-id $POOL_ID \
     --pool-vrf-skey $VRF_SKEY_PATH \
     --byron-genesis $BYRON_GENESIS \
     --shelley-genesis $SHELLEY_GENESIS \
     --ledger-set current
   ```
3. Parses the JSON output (slot assignments)
4. Cross-references with produced blocks from the cncli database
5. Returns enriched slot list with `produced` status

### How Missed Blocks Are Detected

For past slots:
1. Get assigned slots from `cncli leaderlog`
2. Query `cncli` db or chain for blocks at those slots
3. If no block found at an assigned slot → `produced: false`

Categories of "missed" blocks:
- **Height battle** — another pool produced at the same slot, chain picked theirs
- **Ghosted** — block was produced but didn't propagate fast enough
- **Missed** — node was down or couldn't produce in time

### Caching

Leader schedule calculation is expensive (~10-30s). The agent caches results:
- Current epoch schedule: cached until epoch boundary
- Next epoch schedule: cached for 1 hour (recalculated if stake snapshot changes)
- Results stored in memory + optional disk cache
