#!/bin/bash

# Set HTTP proxy
export HTTP_PROXY="http://127.0.0.1:10801"
export HTTPS_PROXY="http://127.0.0.1:10801"
export SOCKS_PROXY="socks5://127.0.0.1:10800"

# Optionally, set lowercase versions as well for compatibility
export http_proxy="http://127.0.0.1:10801"
export https_proxy="http://127.0.0.1:10801"
export socks_proxy="socks5://127.0.0.1:10800"

# Display the configured proxies
echo "HTTP_PROXY is set to $HTTP_PROXY"
echo "HTTPS_PROXY is set to $HTTPS_PROXY"
echo "SOCKS_PROXY is set to $SOCKS_PROXY"
