# Nginx Proxy Manager (z. B. auf Synology/QNAP)

1. `.env`: `APP_BIND=0.0.0.0`, `APP_PORT=8080`, `PUBLIC_APP_URL=https://ants.example.com`
2. In NPM → *Proxy Hosts* → *Add Proxy Host*
   - Domain: `ants.example.com`
   - Scheme `http`, Forward Hostname/IP: IP des Docker-Hosts, Port `8080`
   - *Block Common Exploits* an, *Websockets Support* egal
   - Tab *SSL*: Let's-Encrypt-Zertifikat anfordern, *Force SSL* und *HTTP/2* an
3. Tab *Advanced* (Custom Nginx Configuration):
   ```nginx
   client_max_body_size 64m;
   location /api/v1/sync/events {
       proxy_pass http://<IP-des-Docker-Hosts>:8080;
       proxy_buffering off;
       proxy_read_timeout 1h;
   }
   ```
4. `.env`: `TRUSTED_PROXIES=<IP von NPM>` (bzw. dessen Docker-Netz), damit Rate-Limits die echte Client-IP sehen.
5. `docker compose up -d` und `https://ants.example.com/readyz` aufrufen.
