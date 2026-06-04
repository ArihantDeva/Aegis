# Default-deny egress proxy for the sandbox's hardened network mode.
# The browser container sits on an --internal network with NO route to the
# internet; its ONLY path out is this proxy, which allows ONLY the domains in
# $SANDBOX_ALLOW (comma-separated). Everything else is refused.
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends tinyproxy \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
EXPOSE 8888
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
