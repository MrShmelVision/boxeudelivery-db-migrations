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

    def migration(*arguments):
        run(compose + ['run', '--rm', '--no-deps', 'migrations', *arguments])

    def sql(filename):
        source = (ROOT / 'verification' / filename).read_text()
        result = run(compose + ['exec', '-T', 'postgres', 'psql', '-X', '-At', '-U', 'boxeudelivery',
                               '-d', 'boxeudelivery_validation', '-v', 'ON_ERROR_STOP=1'], source=source, capture=True)
        # Older catalogue checks return booleans; a false is as blocking as a raised assertion.
        if any(line.endswith('|f') for line in result.stdout.splitlines()):
            raise RuntimeError('SQL assertion returned false: ' + filename)

    try:
        run(compose + ['build', 'migrations'])
        for history in ('clean', 'populated-131'):
            run(compose + ['up', '-d', '--wait', '--wait-timeout', '90', 'postgres'])
            if history == 'populated-131':
                migration('-target=131', 'migrate')
                sql('history.sql')
                migration('-target=133', 'migrate')
                sql('known-133-defect.sql')
            migration('migrate')
            migration('migrate')
            migration('validate')
            if history == 'populated-131':
                sql('preserved.sql')
            sql('catalogue.sql')
            sql('remaining-triggers.sql')
            sql('goods-transfer.sql')
            sql('category-appearance.sql')
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
