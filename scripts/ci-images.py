#!/usr/bin/env python3
"""Bind checked application bytes, fresh image scans and publication to one CI run."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / '.local/ci'
SHA = re.compile(r'[0-9a-f]{40}')
DIGEST = re.compile(r'sha256:[0-9a-f]{64}')
sys.dont_write_bytecode = True


def run(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def read(path):
    return json.loads(path.read_text())


def fingerprint(directory, paths):
    digest = hashlib.sha256()
    for path in sorted(paths):
        file = directory / path
        digest.update(str(path).encode() + b'\0')
        if file.is_symlink():
            if not file.resolve().is_relative_to(directory.resolve()):
                raise RuntimeError('Artifact symlink escapes its directory')
            digest.update(b'link\0' + os.readlink(file).encode() + b'\0')
        elif file.is_file():
            digest.update(b'file\0' + hashlib.sha256(file.read_bytes()).digest())
        else:
            raise RuntimeError(f'Expected a regular source/artifact file: {path}')
    return digest.hexdigest()


def context():
    config = read(ROOT / 'ci/project.json')
    if config['kind'] not in ('java', 'website-java', 'vite', 'next', 'database', 'infrastructure', 'knowledge'):
        raise RuntimeError('Unknown CI application recipe')
    revision = os.environ.get('SOURCE_REVISION', run('git', 'rev-parse', 'HEAD'))
    repository = os.environ.get('SOURCE_REPOSITORY', '')
    source_ref = os.environ.get('SOURCE_REF', '')
    if not SHA.fullmatch(revision) or revision != run('git', 'rev-parse', 'HEAD'):
        raise RuntimeError('CI requires the exact checked-out source revision')
    if not re.fullmatch(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+', repository):
        raise RuntimeError('A complete GitHub source repository is required')
    origin = run('git', 'remote', 'get-url', 'origin')
    if origin not in (f'https://github.com/{repository}', f'https://github.com/{repository}.git',
                      f'git@github.com:{repository}.git'):
        raise RuntimeError('CI repository differs from its Git origin')
    if not re.fullmatch(r'refs/(heads/[A-Za-z0-9_./-]+|pull/[0-9]+/merge)', source_ref):
        raise RuntimeError('Unsupported CI source reference')
    if os.environ.get('GITHUB_ACTIONS') == 'true' and run('git', 'status', '--porcelain'):
        raise RuntimeError('CI source checkout changed before artifact qualification')
    paths = [Path(os.fsdecode(p)) for p in subprocess.check_output(
        ['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT).split(b'\0') if p]
    identity = {'revision': revision, 'repository': repository, 'ref': source_ref,
                'run_id': os.environ.get('GITHUB_RUN_ID', 'local'),
                'source_sha256': fingerprint(ROOT, set(paths))}
    declared = {i['name']: i for i in read(ROOT / 'security/project.json')['images']}
    names = set()
    for image in config['images']:
        name = image['name']
        if name not in declared or name in names:
            raise RuntimeError('CI image inventory differs from the security inventory')
        names.add(name)
        if not re.fullmatch(r'ghcr\.io/' + repository.split('/')[0].lower() + r'/[a-z0-9-]+', image['repository']):
            raise RuntimeError('CI publication requires the existing owner GHCR namespace')
    if config['kind'] not in ('infrastructure', 'knowledge') and names != set(declared):
        raise RuntimeError('CI must qualify every declared deployment image')
    return config, identity, declared


def output(values):
    destination = os.environ.get('GITHUB_OUTPUT')
    if destination:
        with open(destination, 'a') as stream:
            for key, value in values.items():
                if '\n' in str(value):
                    raise RuntimeError('Invalid CI output')
                stream.write(f'{key}={value}\n')
    print(json.dumps(values))


def metadata(config):
    values = {'kind': config['kind'], 'artifact': str(bool(config.get('artifact'))).lower(),
              'node_version': config.get('node_version', ''),
              'go_layers': str(any(i.get('go_binary') for i in read(ROOT / 'security/project.json')['images'])).lower()}
    if config['kind'] == 'website-java':
        revision = (ROOT / 'database-source-revision.txt').read_text().strip()
        if not SHA.fullmatch(revision):
            raise RuntimeError('Expected the complete reviewed database source revision')
        values['database_revision'] = revision
    return values


def seal(config, identity):
    (STATE / 'application.json').unlink(missing_ok=True)
    (STATE / 'application.tar.gz').unlink(missing_ok=True)
    source = ROOT / config['artifact']
    application = STATE / 'application'
    shutil.rmtree(application, ignore_errors=True)
    application.mkdir(parents=True)
    destination = application / config['artifact_destination']
    if source.is_dir():
        shutil.copytree(source, destination, symlinks=True)
    elif source.is_file() and not source.is_symlink():
        shutil.copy2(source, destination)
    else:
        raise RuntimeError('The application check did not produce its required artifact')
    payload = STATE / 'application.tar.gz'
    with tarfile.open(payload, 'w:gz', compresslevel=1) as archive:
        archive.add(application, arcname='application')
    paths = [p.relative_to(application) for p in application.rglob('*') if p.is_file() or p.is_symlink()]
    receipt = {**identity, 'payload_sha256': hashlib.sha256(payload.read_bytes()).hexdigest(),
               'application_sha256': fingerprint(application, paths)}
    (STATE / 'application.json').write_text(json.dumps(receipt, indent=2) + '\n')


def checked_artifact(identity, *, unpack=False):
    receipt = read(STATE / 'application.json')
    if any(receipt.get(k) != v for k, v in identity.items()):
        raise RuntimeError('Application artifact belongs to another source or CI run')
    payload = STATE / 'application.tar.gz'
    if hashlib.sha256(payload.read_bytes()).hexdigest() != receipt['payload_sha256']:
        raise RuntimeError('Application artifact checksum mismatch')
    if unpack:
        with tempfile.TemporaryDirectory(dir=STATE, prefix='unpack-') as temporary:
            with tarfile.open(payload, 'r:gz') as archive:
                entries = archive.getmembers()
                if sum(e.size for e in entries) > 512 * 1024 * 1024:
                    raise RuntimeError('Application artifact exceeds its bounded extraction size')
                if any(not e.name.startswith('application/') and e.name != 'application' for e in entries):
                    raise RuntimeError('Application archive contains an unexpected path')
                archive.extractall(temporary, filter='data')
            shutil.rmtree(STATE / 'application', ignore_errors=True)
            shutil.move(str(Path(temporary) / 'application'), STATE / 'application')
    application = STATE / 'application'
    paths = [p.relative_to(application) for p in application.rglob('*') if p.is_file() or p.is_symlink()]
    if fingerprint(application, paths) != receipt['application_sha256']:
        raise RuntimeError('Staged application bytes differ from the checked artifact')


def scanner():
    spec = importlib.util.spec_from_file_location('boxeu_security', ROOT / 'scripts/security-check.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    module.provision()
    return module


def labels(config, identity, image):
    values = {'org.opencontainers.image.source': f'https://github.com/{identity["repository"]}',
              'org.opencontainers.image.revision': identity['revision'], 'com.boxeu.source.ref': identity['ref']}
    if image.get('schema_manifest'):
        values['com.boxeu.website.schema.sha256'] = hashlib.sha256((ROOT / image['schema_manifest']).read_bytes()).hexdigest()
    return values


def image_identity(config, identity, image, target):
    details = json.loads(run('docker', 'image', 'inspect', target))[0]
    if not DIGEST.fullmatch(details.get('Id', '')) or details.get('Os') != 'linux' or details.get('Architecture') != 'amd64':
        raise RuntimeError('Candidate must be an immutable Linux AMD64 image')
    if details['Config'].get('User', '').split(':', 1)[0] in ('', 'root', '0'):
        raise RuntimeError('Publication candidate must run as a non-root user')
    actual = details['Config'].get('Labels') or {}
    if any(actual.get(k) != v for k, v in labels(config, identity, image).items()):
        raise RuntimeError('Image labels differ from the checked source and schema')
    return details['Id']


def tag(identity, image):
    return image['repository'] + ':sha-' + identity['revision']


def build(config, identity, declared):
    (STATE / 'scanned.json').unlink(missing_ok=True)
    if config.get('artifact'):
        checked_artifact(identity)
    security = scanner()
    def candidate(image):
        recipe = {**declared[image['name']], 'labels': labels(config, identity, image)}
        recipe['build_args'] = {**recipe.get('build_args', {}), **image.get('build_args', {})}
        if config['kind'] == 'vite':
            recipe['build_args']['VITE_BUILD_REVISION'] = identity['revision']
        security.build_image(ROOT, recipe, tag(identity, image))
        image_identity(config, identity, image, tag(identity, image))
    with ThreadPoolExecutor(max_workers=min(3, len(config['images']))) as pool:
        list(pool.map(candidate, config['images']))


def scan(config, identity, *, published=False):
    (STATE / 'scanned.json').unlink(missing_ok=True)
    security = scanner()
    images = []
    for image in config['images']:
        target = tag(identity, image)
        if published:
            subprocess.run(['docker', 'pull', '--platform', 'linux/amd64', target], cwd=ROOT, check=True)
            digests = json.loads(run('docker', 'image', 'inspect', target))[0].get('RepoDigests') or []
            target = next((d for d in digests if d.startswith(image['repository'] + '@sha256:')), '')
            if not target:
                raise RuntimeError('Published candidate has no matching immutable registry digest')
        image_id = image_identity(config, identity, image, target)
        report = STATE / 'scans' / image['name']
        report.mkdir(parents=True, exist_ok=True)
        if security.trivy_scan(target if published else image_id, report / 'trivy.json', image=True):
            raise RuntimeError('Image blocked: security findings detected')
        security.image_sbom(target if published else image_id, report / 'sbom.cdx.json', report / 'trivy.json')
        images.append({'name': image['name'], 'target': target, 'image_id': image_id})
    (STATE / 'scanned.json').write_text(json.dumps({**identity, 'images': images}, indent=2) + '\n')


def publish(config, identity):
    if os.environ.get('GITHUB_ACTIONS') != 'true' or identity['ref'] != 'refs/heads/' + config['default_branch']:
        raise RuntimeError('Publication is restricted to the existing default-branch GitHub release workflow')
    if os.environ.get('GITHUB_EVENT_NAME') not in ('push', 'workflow_dispatch'):
        raise RuntimeError('Pull requests and scheduled checks cannot publish')
    receipt = read(STATE / 'scanned.json')
    if any(receipt.get(k) != v for k, v in identity.items()) or len(receipt['images']) != len(config['images']):
        raise RuntimeError('Publication requires all fresh image checks from this run')
    for image, checked in zip(config['images'], receipt['images']):
        target = tag(identity, image)
        if checked['name'] != image['name'] or checked['target'] != target or image_identity(config, identity, image, target) != checked['image_id']:
            raise RuntimeError('Publication candidate changed after its scan')
    # Publish revision identities first. Moving tags only advance after all
    # candidates were scanned and every immutable revision push succeeded.
    for image in config['images']:
        subprocess.run(['docker', 'push', tag(identity, image)], check=True)
    for image in config['images']:
        for moving in image.get('moving_tags', []):
            if not re.fullmatch(r'[a-z0-9-]+', moving):
                raise RuntimeError('Invalid environment image tag')
            destination = image['repository'] + ':' + moving
            subprocess.run(['docker', 'tag', tag(identity, image), destination], check=True)
            subprocess.run(['docker', 'push', destination], check=True)


def plan(config, identity):
    reuse = False
    if os.environ.get('GITHUB_EVENT_NAME') == 'schedule' and config['images']:
        if identity['ref'] != 'refs/heads/' + config['default_branch']:
            raise RuntimeError('Scheduled rescan requires the current default branch')
        token = os.environ.get('GH_TOKEN')
        if not token:
            raise RuntimeError('Scheduled qualification requires the read-only Actions token')
        for event in ('push', 'workflow_dispatch'):
            query = urllib.parse.urlencode({'head_sha': identity['revision'], 'status': 'success',
                                            'event': event, 'per_page': 100})
            url = f'https://api.github.com/repos/{identity["repository"]}/actions/runs?{query}'
            request = urllib.request.Request(url, headers={'Authorization': 'Bearer ' + token,
                'Accept': 'application/vnd.github+json', 'X-GitHub-Api-Version': '2026-03-10'})
            with urllib.request.urlopen(request, timeout=30) as response:
                runs = json.load(response)['workflow_runs']
            reuse = any(r['head_sha'] == identity['revision'] and r['head_branch'] == config['default_branch']
                        and r['path'] == '.github/workflows/' + config['release_workflow']
                        and r['event'] == event and r['conclusion'] == 'success' for r in runs)
            if reuse:
                break
    output({**metadata(config), 'reuse': str(reuse).lower()})


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('context', 'plan', 'seal', 'unpack', 'build', 'scan', 'rescan', 'publish'))
    command = parser.parse_args().command
    STATE.mkdir(parents=True, exist_ok=True)
    config, identity, declared = context()
    if command == 'context':
        output(metadata(config))
    elif command == 'plan':
        plan(config, identity)
    elif command == 'seal':
        seal(config, identity)
    elif command == 'unpack':
        checked_artifact(identity, unpack=True)
    elif command == 'build':
        build(config, identity, declared)
    elif command in ('scan', 'rescan'):
        scan(config, identity, published=command == 'rescan')
    else:
        publish(config, identity)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as error:
        raise SystemExit(f'CI qualification failed: {error}')
