# dbcraft: PostgreSQL 16 + PL/Python + the dbcraft schema + the recommended server configuration (docs/TUNING.md).
#
# Mojang data is NOT in the image.  Mount your own data generator reports at /data/reports (required for block/item/packet ids) and, for the configuration
# phase (registries, tags, a few opaque packets), a vanilla capture directory at /data/captures (tools/capture_vanilla.py output).  See docker/README.md.
FROM postgres:16

RUN apt-get update \
 && apt-get install -y --no-install-recommends postgresql-plpython3-16 python3 \
 && rm -rf /var/lib/apt/lists/*

ENV DBCRAFT_HOME=/opt/dbcraft \
    DBCRAFT_REPORTS=/data/reports \
    DBCRAFT_CAPTURES=/data/captures \
    DBCRAFT_DEV_GATEWAY=0 \
    DBCRAFT_GATEWAY_PORT=25565

WORKDIR /opt/dbcraft
COPY sql   /opt/dbcraft/sql
COPY tools /opt/dbcraft/tools
COPY docker/postgresql.conf /etc/dbcraft/postgresql.conf
COPY docker/initdb.d/10-dbcraft.sh /docker-entrypoint-initdb.d/10-dbcraft.sh
COPY docker/entrypoint.sh /usr/local/bin/dbcraft-entrypoint.sh
RUN chmod +x /docker-entrypoint-initdb.d/10-dbcraft.sh /usr/local/bin/dbcraft-entrypoint.sh \
 && chmod +x /opt/dbcraft/tools/*.sh /opt/dbcraft/tools/*.py

# 5432: PostgreSQL (keep it private); 25565: the development gateway (call net.run), only when DBCRAFT_DEV_GATEWAY=1
EXPOSE 5432 25565
ENTRYPOINT ["dbcraft-entrypoint.sh"]
CMD ["postgres", "-c", "config_file=/etc/dbcraft/postgresql.conf"]
