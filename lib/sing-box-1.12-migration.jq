.dns = {
  "servers": [
    {
      "type": "tls",
      "tag": "google-dns",
      "server": "8.8.8.8",
      "server_port": 853
    }
  ]
} |
del(.outbounds) |
.route = {"rules":[{"port":53,"action":"hijack-dns"}]}
