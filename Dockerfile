FROM flyway/flyway:13.9.0-alpine@sha256:ae8e985a8caf73181a39aad823690f27d55c850d4c5cea92a94c0ce4b3943156

# BoxEU connects only to PostgreSQL. Do not ship unrelated JDBC driver bundles.
RUN apk upgrade --no-cache \
    && apk add --no-cache 'zlib>=1.3.2-r1' 'libexpat>=2.9.0-r0' \
    && find /flyway/drivers -mindepth 1 -maxdepth 1 ! -name 'postgresql-*.jar' -exec rm -rf {} + \
    && find /flyway/lib/flyway -maxdepth 1 -name 'flyway-database-*.jar' \
       ! -name 'flyway-database-postgresql-*.jar' -delete \
    && rm -f /flyway/lib/flyway/flyway-mysql-*.jar /flyway/lib/flyway/flyway-sqlserver-*.jar \
       /flyway/lib/flyway/flyway-singlestore-*.jar /flyway/lib/flyway/flyway-firebird-*.jar \
       /flyway/lib/flyway/flyway-gcp-*.jar /flyway/lib/flyway/flyway-locations-s3-*.jar

COPY migrations /flyway/migrations
COPY fixtures /flyway/fixtures

ENV FLYWAY_LOCATIONS=filesystem:/flyway/migrations,filesystem:/flyway/fixtures \
    FLYWAY_CONNECT_RETRIES=30 \
    FLYWAY_CLEAN_DISABLED=true \
    FLYWAY_OUT_OF_ORDER=false \
    FLYWAY_VALIDATE_MIGRATION_NAMING=true \
    FLYWAY_ENCODING=UTF-8

USER 10001:10001
CMD ["migrate"]

# One-shot migration job; successful exit is its deployment readiness gate.
HEALTHCHECK NONE
