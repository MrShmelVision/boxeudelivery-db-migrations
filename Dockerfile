FROM flyway/flyway:13.12.2-alpine@sha256:f5b9740a05ef38fc31356dcf2e7796dafc693ea289546e82c7699d37f83349af

# BoxEU connects only to PostgreSQL. Do not ship unrelated JDBC driver bundles.
RUN apk upgrade --no-cache \
    && apk add --no-cache 'musl>=1.2.6-r3' 'musl-utils>=1.2.6-r3' 'brotli-libs>=1.2.1-r0' 'zlib>=1.4-r0' 'libexpat>=2.11.0-r0' 'libfontenc>=1.1.10-r0' 'openssl>=3.5.9-r1' 'libssl3>=3.5.9-r1' 'libcrypto3>=3.5.9-r1' \
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
