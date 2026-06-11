# Description
Veradoc Web

# Deploy steps
deploy.sh runs
  → detects host IP (e.g. 192.168.1.50)
  → sets API_URL=http://192.168.1.50:8808
  → docker compose up
    → veradoc-ui container starts
      → entrypoint.sh runs envsubst
        → generates /usr/share/nginx/html/env.js with real IP
          → Angular loads env.js → window.__env.apiUrl = "http://192.168.1.50:8808"