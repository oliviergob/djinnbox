# Dev Container

This is the `dev-ssh-persist` development container. The following ports are forwarded to the Windows host:

| Port | Use |
|------|-----|
| 8100 | Web server (primary) |
| 8200 | Web server |
| 8300 | Web server |

When starting any web server (dev server, preview, API, etc.), always bind to one of these ports — default to **8100** unless it is already in use. Services bound to any other port will not be reachable from Windows.
