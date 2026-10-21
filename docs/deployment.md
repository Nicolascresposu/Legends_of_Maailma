# Deployment

The server ships as a Docker image. `deploy/docker-compose.yml` runs it with its own Postgres, on a
machine that is reached from the internet through a VPS:

```text
Godot client ──https/wss──▶ nginx (VPS, TLS) ──▶ frps (VPS) ══tunnel══ frpc (home) ──▶ server container ──▶ db container
```

Only nginx is public. frps publishes the tunnel on the VPS's loopback, and the container publishes
on the home machine's loopback, so plain HTTP is never reachable from outside.

## The server

On the home machine, with Docker and the repository checked out:

```bash
cd deploy
cp .env.example .env          # set POSTGRES_PASSWORD, e.g. `openssl rand -hex 24`
docker compose up -d --build
docker compose logs -f server
curl http://127.0.0.1:3000/health   # {"ok":true,"service":"maailma-tcg","database":"up"}
```

`up` starts Postgres, waits for it, applies any pending migrations with `prisma migrate deploy`,
and only then starts the server. To deploy a new version:

```bash
git pull
cd deploy && docker compose up -d --build
```

Matches in progress live in server memory, so a restart ends them. Accounts, decks and collections
are in the `db-data` volume and survive rebuilds.

Do not run `npm run seed` against this database: it creates accounts with a shared, published
password.

### The first admin

No account is an admin to begin with. Register one from the client, then:

```bash
docker compose exec db psql -U maailma -d maailma \
  -c "UPDATE users SET \"isAdmin\" = true WHERE email = 'you@example.com';"
```

Further admins can be made from the Admin UI.

### Backups

```bash
docker compose exec -T db pg_dump -U maailma -d maailma --clean > maailma-$(date +%F).sql
docker compose exec -T db psql -U maailma -d maailma < maailma-2026-09-23.sql   # restore
```

## frp

`frpc.toml` on the home machine, forwarding to the port the container publishes:

```toml
serverAddr = "vps.example.com"
serverPort = 7000
auth.token = "your-frp-token"

[[proxies]]
name = "maailma"
type = "tcp"
localIP = "127.0.0.1"
localPort = 3000
remotePort = 3000
```

In `frps.toml` on the VPS, bind tunnels to loopback so the port is only reachable through nginx:

```toml
proxyBindAddr = "127.0.0.1"
```

If frpc itself runs in a container, `127.0.0.1` is that container, not the host: set
`BIND_ADDRESS=0.0.0.0` in `deploy/.env` and point `localIP` at the host, or put frpc on the
compose network and use `localIP = "server"`, `localPort = 3000`.

If you already route frp through `type = "http"` with `customDomains` and frps's `vhostHTTPPort`,
that works too: point nginx's `proxy_pass` at the vhost port and keep the `Host` header.

## nginx

The server needs WebSocket upgrades on `/matches` and `/lobby`, and it does not ping idle sockets,
so the read timeout must outlast a quiet turn. The lobby socket carries the session token in its
query string, so that location keeps it out of the access log.

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl;
    http2 on;
    server_name maailma.example.com;

    ssl_certificate     /etc/letsencrypt/live/maailma.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/maailma.example.com/privkey.pem;

    proxy_http_version 1.1;
    proxy_set_header Upgrade           $http_upgrade;
    proxy_set_header Connection        $connection_upgrade;
    proxy_set_header Host              $host;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 1h;
    proxy_send_timeout 1h;

    location / {
        proxy_pass http://127.0.0.1:3000;
    }

    location = /lobby {
        access_log off;
        proxy_pass http://127.0.0.1:3000;
    }
}

server {
    listen 80;
    server_name maailma.example.com;
    return 301 https://$host$request_uri;
}
```

## The client

Point the client at the public address, with `https://` so it uses `wss://` for its sockets:

```bash
godot --path apps/godot-client -- --server=https://maailma.example.com
```

or enter `https://maailma.example.com` as the server address on the sign-in screen, which saves
it.
