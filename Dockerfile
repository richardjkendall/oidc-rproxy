# Ubuntu 24.04 (Apache 2.4.58), up from 18.04 (Apache 2.4.29, EOL since 2023).
#
# The Apache version matters here, it is not just hygiene: ProxyPass gained the
# `upgrade=` parameter in 2.4.47, which lets mod_proxy_http handle WebSocket
# upgrades end-to-end. On 2.4.29 that had to be done with a mod_rewrite [P]
# rule, which was subtly wrong for years — see config/oidc_auth.conf.
FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      apache2 \
      gettext-base \
      libapache2-mod-auth-openidc \
      ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# a2enmod rather than hand-made symlinks into mods-enabled: it also pulls in
# each module's .conf where one exists, which the symlinks silently did not.
#
# proxy_wstunnel is kept enabled although ProxyPass upgrade=websocket no longer
# needs it, so that ProxyWebsocketFallbackToProxyHttp has something to fall back
# to and older configs keep working.
RUN a2enmod proxy proxy_http proxy_wstunnel rewrite headers

COPY config/oidc_auth.conf /apache.conf
COPY docker-entrypoint.sh /
ENTRYPOINT ["/docker-entrypoint.sh"]

EXPOSE 80

CMD /usr/sbin/apache2ctl -D FOREGROUND
