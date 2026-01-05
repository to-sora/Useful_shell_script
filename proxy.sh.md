# proxy.sh

Set HTTP/HTTPS/SOCKS proxy environment variables to local ports.

## Usage
```bash
source ./proxy.sh
```

## Notes
- Sets both uppercase and lowercase proxy variables.
- Uses `127.0.0.1:10801` for HTTP/HTTPS and `127.0.0.1:10800` for SOCKS.
