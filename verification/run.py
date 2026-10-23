#!/usr/bin/env python3
"""Exercise the actual complete Flyway chain and every current CRM trigger in owned PostgreSQL."""
import os
from pathlib import Path
import subprocess
import sys
import uuid

ROOT = Path(__file__).resolve().parents[1]


def main():
    project = 'boxeu-schema-' + uuid.uuid4().hex[:12]
    compose = ['docker', 'compose', '--project-name', project, '-f', str(ROOT / 'compose.validation.yaml')]
    environment = {key: value for key, value in os.environ.items() if not key.startswith('COMPOSE_')}

    def run(arguments, *, source=None, capture=False):
        return subprocess.run(arguments, cwd=ROOT, env=environment, input=source, text=True,
                              stdout=subprocess.PIPE if capture else None, check=True, timeout=600)

    def migration(*arguments, historical=False):
        if historical:
            # Reconstruct the fixture inventory that existed before navigation groups.
            script = ('mkdir -p /tmp/history-fixtures && '
                      'cp /flyway/fixtures/R__01_account_reference_data.sql '
                      '/flyway/fixtures/R__02_currency_reference_data.sql '
                      '/flyway/fixtures/R__03_country_reference_data.sql /tmp/history-fixtures/ && '
                      'exec /flyway/flyway -locations=filesystem:/flyway/migrations,filesystem:/tmp/history-fixtures "$@"')
            run(compose + ['run', '--rm', '--no-deps', '--entrypoint', 'sh', 'migrations',
                           '-c', script, 'historical-fixtures', *arguments])
        else:
            run(compose + ['run', '--rm', '--no-deps', 'migrations', *arguments])

    def sql(filename):
        source = (ROOT / 'verification' / filename).read_text()
        result = run(compose + ['exec', '-T', 'postgres', 'psql', '-X', '-At', '-U', 'boxeudelivery',
                               '-d', 'boxeudelivery_validation', '-v', 'ON_ERROR_STOP=1'], source=source, capture=True)
        # Older catalogue checks return booleans; a false is as blocking as a raised assertion.
        if any(line.endswith('|f') for line in result.stdout.splitlines()):
            raise RuntimeError('SQL assertion returned false: ' + filename)

    def catalog_notifications():
        project_id = '11111111-1111-4111-8111-111111111111'
        source = f"""
LISTEN website_catalog_changes;
BEGIN;
INSERT INTO crm.website_catalog_revision(project_id,transaction_id)
VALUES('{project_id}',txid_current()) ON CONFLICT DO NOTHING;
INSERT INTO crm.website_catalog_revision(project_id,transaction_id)
VALUES('{project_id}',txid_current()) ON CONFLICT DO NOTHING;
SELECT 'catalog_uncommitted';
COMMIT;
SELECT 'catalog_committed';
BEGIN;
INSERT INTO crm.website_catalog_revision(project_id,transaction_id)
VALUES('{project_id}',txid_current()) ON CONFLICT DO NOTHING;
ROLLBACK;
SELECT 'catalog_rolled_back';
"""
        result = run(compose + ['exec', '-T', 'postgres', 'psql', '-X', '-At', '-U', 'boxeudelivery',
                               '-d', 'boxeudelivery_validation', '-v', 'ON_ERROR_STOP=1'], source=source, capture=True)
        signal = f'Asynchronous notification "website_catalog_changes" with payload "{project_id}"'
        if result.stdout.count(signal) != 1 or not (
                result.stdout.index('catalog_uncommitted') < result.stdout.index(signal)
                < result.stdout.index('catalog_committed')):
            raise RuntimeError('Catalogue notification must occur once after commit and never after rollback')
        print('PASS committed catalogue notification, transaction coalescing and rollback', flush=True)

    try:
        run(compose + ['build', 'migrations'])
        for history in ('clean', 'populated-131'):
            run(compose + ['up', '-d', '--wait', '--wait-timeout', '90', 'postgres'])
            if history == 'populated-131':
                migration('-target=131', 'migrate', historical=True)
                sql('history.sql')
                migration('-target=133', 'migrate', historical=True)
                sql('known-133-defect.sql')
                migration('-target=144', 'migrate', historical=True)
                sql('hierarchy-history.sql')
            migration('migrate')
            migration('migrate')
            migration('validate')
            if history == 'populated-131':
                sql('preserved.sql')
            sql('catalogue.sql')
            catalog_notifications()
            sql('remaining-triggers.sql')
            sql('goods-transfer.sql')
            sql('category-appearance.sql')
            sql('catalogue-hierarchy.sql')
            print('PASS full-schema migration and trigger execution: ' + history, flush=True)
            run(compose + ['rm', '--stop', '--force', '--volumes', 'postgres'])
    finally:
        subprocess.run(compose + ['down', '--volumes', '--remove-orphans'], cwd=ROOT, env=environment,
                       check=False, timeout=120)


if __name__ == '__main__':
    try:
        main()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired, RuntimeError) as error:
        print('Full-schema verification FAILED: ' + str(error), file=sys.stderr)
        sys.exit(1)
