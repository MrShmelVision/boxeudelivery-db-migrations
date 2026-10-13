#!/usr/bin/env python3
"""Fail-closed local/CI security gate. Standard library only; no cloud scan uploads."""
import argparse
from datetime import datetime, timezone
import fcntl
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import re
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import urllib.request


ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / '.local/security'
TOOLS = STATE / 'tools'
SEVERITIES = 'UNKNOWN,LOW,MEDIUM,HIGH,CRITICAL'


def run(args, *, cwd=ROOT, capture=False, accepted=(0,)):
    environment = {key: value for key, value in os.environ.items()
                   if not key.startswith(('TRIVY_', 'GITLEAKS_', 'SEMGREP_'))}
    cache_lock = None
    try:
        if Path(str(args[0])).name == 'trivy':
            # Trivy's filesystem cache permits one process at a time. Different
            # repository hooks must not race and produce cache-lock failures.
            shared = Path.home() / '.cache/boxeu-security'
            shared.mkdir(parents=True, exist_ok=True, mode=0o700)
            cache_lock = (shared / 'trivy.lock').open('a')
            try:
                fcntl.flock(cache_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print('Waiting for another BoxEU Trivy scan to release its cache...', flush=True)
                fcntl.flock(cache_lock, fcntl.LOCK_EX)
        result = subprocess.run([str(x) for x in args], cwd=cwd, text=True,
                                env=environment,
                                stdout=subprocess.PIPE if capture else None,
                                stderr=subprocess.PIPE if capture else None)
    finally:
        if cache_lock:
            cache_lock.close()
    if result.returncode not in accepted:
        # Scanner output can contain source/secrets. Keep captured output private.
        if capture:
            STATE.mkdir(parents=True, exist_ok=True)
            (STATE / 'last-tool-error.log').write_text((result.stdout or '') + (result.stderr or ''))
        raise RuntimeError(f'{Path(str(args[0])).name} failed (exit {result.returncode})')
    return result


def read_json(path):
    with path.open() as stream:
        return json.load(stream)


def provision():
    spec = read_json(ROOT / 'security/toolchain.json')
    machine = platform.machine()
    key = platform.system() + '-' + ('arm64' if machine in ('aarch64', 'arm64') else machine)
    TOOLS.mkdir(parents=True, exist_ok=True)
    for name in ('trivy', 'gitleaks', 'actionlint'):
        entry = spec[name]
        if key not in entry['assets']:
            raise RuntimeError(f'Unsupported scanner platform: {key}')
        asset, checksum = entry['assets'][key]
        archive = TOOLS / asset
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
            print(f'Downloading {name} {entry["version"]} (SHA-256 verified)', flush=True)
            url = f'https://github.com/{entry["repository"]}/releases/download/v{entry["version"]}/{asset}'
            context = ssl.create_default_context()
            if platform.system() == 'Darwin':
                # Portable Python runtimes may not ship the host CA path. Keep TLS verification
                # enabled and augment it with the trusted macOS system roots.
                roots = subprocess.check_output(['/usr/bin/security', 'find-certificate', '-a', '-p',
                    '/System/Library/Keychains/SystemRootCertificates.keychain'])
                context.load_verify_locations(cadata=roots.decode('ascii'))
            with urllib.request.urlopen(url, timeout=120, context=context) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != checksum:
                raise RuntimeError(f'{name} archive checksum mismatch')
            archive.write_bytes(data)
        with tarfile.open(archive, 'r:gz') as stream:
            member = stream.getmember(name)
            if not member.isfile():
                raise RuntimeError('Scanner archive does not contain a regular executable')
            with stream.extractfile(member) as binary:
                data = binary.read()
        target = TOOLS / name
        if not target.exists() or target.read_bytes() != data:
            target.write_bytes(data)
            target.chmod(0o700)
    return spec


def export_source(destination, revision=None, staged=False):
    if revision or staged:
        args = ['git', 'archive', revision or run(['git', 'write-tree'], capture=True).stdout.strip()]
        result = subprocess.run(args, cwd=ROOT, stdout=subprocess.PIPE, check=True)
        with tarfile.open(fileobj=io.BytesIO(result.stdout), mode='r:') as archive:
            archive.extractall(destination, filter='data')
    else:
        paths = subprocess.check_output(['git', 'ls-files', '-z', '--cached', '--others', '--exclude-standard'], cwd=ROOT)
        for raw in set(paths.split(b'\0')) - {b''}:
            path = Path(os.fsdecode(raw))
            source = ROOT / path
            if source.is_symlink():
                raise RuntimeError(f'Source symlink requires review: {path}')
            if source.is_file():
                target = destination / path
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source, target)


def secret_scan(source, report, *, revision=None):
    args = [TOOLS / 'gitleaks', 'git' if revision else 'dir', '--no-banner', '--redact=100',
            '--ignore-gitleaks-allow', '--gitleaks-ignore-path', source / 'security/no-ignore-file',
            '--config', source / 'security/gitleaks.toml', '--report-format', 'json', '--report-path', report]
    if revision:
        args += ['--log-opts', revision, ROOT]
    else:
        args += [source]
    run(args, capture=True, accepted=(0, 1))
    findings = read_json(report)
    for item in findings:
        prefix = str(source) + '/'
        if item['File'].startswith(prefix):
            item['File'] = item['File'][len(prefix):]
        print(f'  SECRET {item["RuleID"]} {item["File"]}:{item["StartLine"]}')
    report.write_text(json.dumps(findings, indent=2) + '\n')
    return len(findings)


def build_image(source, image, tag, *, capture=False):
    cached = os.environ.get('BOXEU_BUILDX_CACHE') == 'true'
    args = ['docker', *(['buildx', 'build', '--load'] if cached else ['build']),
            '--pull', '--platform=linux/amd64', '--tag', tag,
            '--file', source / image['dockerfile']]
    if cached:
        args += ['--provenance=false']
    for key, value in image.get('labels', {}).items():
        args += ['--label', f'{key}={value}']
    cache = None
    pending = None
    if cached:
        name = image['name']
        if not re.fullmatch(r'[a-z0-9][a-z0-9-]*', name):
            raise RuntimeError('Invalid BuildKit cache slot')
        cache = STATE / 'buildkit-cache' / name
        pending = cache.with_name(name + '-next')
        cache.parent.mkdir(parents=True, exist_ok=True)
        if pending.exists():
            shutil.rmtree(pending)
        if (cache / 'index.json').is_file():
            args += ['--cache-from', f'type=local,src={cache}']
        args += ['--cache-to', f'type=local,dest={pending},mode=max']
    for key, value in image.get('build_args', {}).items():
        args += ['--build-arg', f'{key}={value}']
    try:
        run([*args, source / image['context']], capture=capture)
        if cached:
            if cache.exists():
                shutil.rmtree(cache)
            pending.rename(cache)
    finally:
        if pending and pending.exists():
            shutil.rmtree(pending)


def json_messages(value):
    decoder = json.JSONDecoder()
    messages = []
    value = value.lstrip()
    while value:
        item, length = decoder.raw_decode(value)
        messages.append(item)
        value = value[length:].lstrip()
    return messages


def verify_openpgp_absent(target, binary_path, version, destination):
    """Fresh, artifact-bound package absence evidence for GO-2026-5932 only."""
    image_id = run(['docker', 'image', 'inspect', '--format', '{{.Id}}', target], capture=True).stdout.strip()
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', image_id):
        raise RuntimeError('Go package verification requires an immutable local image')
    destination.mkdir(parents=True, exist_ok=True)
    for name in ('inventory.json', 'govulncheck.json', 'proof.json'):
        (destination / name).unlink(missing_ok=True)
    recipe = ROOT / 'security/govulncheck.Dockerfile'
    pin = read_json(ROOT / 'security/toolchain.json')['govulncheck']
    if hashlib.sha256(recipe.read_bytes()).hexdigest() != pin['dockerfile_sha256']:
        raise RuntimeError('Go verifier recipe checksum mismatch')
    tool_tag = 'boxeu-security/govulncheck:' + pin['dockerfile_sha256'][:16]
    build_image(ROOT, {'name': 'govulncheck', 'dockerfile': 'security/govulncheck.Dockerfile',
                      'context': 'security'}, tool_tag, capture=True)
    tool_id = run(['docker', 'image', 'inspect', '--format', '{{.Id}}', tool_tag], capture=True).stdout.strip()
    with tempfile.TemporaryDirectory(prefix='boxeu-go-binary-') as directory:
        temporary = Path(directory)
        container = run(['docker', 'create', '--network=none', '--entrypoint', '/bin/false', image_id], capture=True).stdout.strip()
        try:
            name = Path(binary_path).name
            run(['docker', 'cp', f'{container}:{binary_path}', temporary / 'binary'], capture=True)
            for suffix in ('packages', 'sha256'):
                run(['docker', 'cp', f'{container}:/usr/share/boxeu-security/{name}.{suffix}',
                     temporary / suffix], capture=True)
        finally:
            run(['docker', 'rm', container], capture=True, accepted=(0, 1))
        fingerprint = hashlib.sha256((temporary / 'binary').read_bytes()).hexdigest()
        if (temporary / 'sha256').read_text().split()[0] != fingerprint:
            raise RuntimeError('Compiler package receipt does not match the scanned Go binary')
        packages = set((temporary / 'packages').read_text().splitlines())
        if 'runtime' not in packages or len(packages) < 2:
            raise RuntimeError('Compiler package receipt is incomplete')
        if any(p == 'golang.org/x/crypto/openpgp' or p.startswith('golang.org/x/crypto/openpgp/') for p in packages):
            return None
        base = ['docker', 'run', '--rm', '--read-only', '--cap-drop=ALL', '--security-opt=no-new-privileges',
                '--memory=1g', '--pids-limit=128', '--tmpfs', '/tmp:rw,nosuid,size=128m',
                '--user', f'{os.getuid()}:{os.getgid()}', '-e', 'HOME=/tmp',
                '-v', f'{temporary / "binary"}:/binary:ro']
        inventory_output = run([*base, '--network=none', tool_id, '-mode=extract', '/binary'], capture=True).stdout
        (destination / 'inventory.json').write_text(inventory_output)
        inventory = json_messages(inventory_output)
        if len(inventory) != 2 or inventory[0] != {'name': 'govulncheck-extract', 'version': '0.1.0'}:
            raise RuntimeError('Unsupported Go binary inventory protocol')
        body = inventory[1]
        symbols = body.get('pkgSymbols')
        if not symbols or body.get('goos') != 'linux' or body.get('path') not in packages:
            raise RuntimeError('Go verifier did not extract a complete Linux binary inventory')
        modules = body.get('modules', [])
        if not any(m['Path'] == 'golang.org/x/crypto' and m['Version'] == version for m in modules):
            raise RuntimeError('Go binary crypto version differs from the dependency finding')
        if any(s.get('pkg', '').startswith('golang.org/x/crypto/openpgp') for s in symbols):
            return None
        output = run([*base, '-e', 'GOVULNDB=https://vuln.go.dev', tool_id,
                      '-mode=binary', '-scan=package', '-json', '/binary'], capture=True).stdout
        (destination / 'govulncheck.json').write_text(output)
        messages = json_messages(output)
        config = next((m['config'] for m in messages if 'config' in m), {})
        if (config.get('scanner_version') != 'v' + pin['version'] or config.get('scan_level') != 'package'
                or config.get('scan_mode') != 'binary' or config.get('db') != 'https://vuln.go.dev'):
            raise RuntimeError('Unexpected Go vulnerability analysis configuration')
        # JSON output exits zero even for findings; inspect the actual package traces.
        linked = [m['finding']['osv'] for m in messages if 'finding' in m
                  and any(frame.get('package') for frame in m['finding'].get('trace', []))]
        if linked:
            raise RuntimeError('Go binary contains vulnerable packages: ' + ', '.join(sorted(set(linked))))
        advisory = next((m['osv'] for m in messages if m.get('osv', {}).get('id') == 'GO-2026-5932'), {})
        affected = advisory.get('affected', [])
        imports = [p['path'] for a in affected for p in a.get('ecosystem_specific', {}).get('imports', [])]
        if (not imports or any(not p.startswith('golang.org/x/crypto/openpgp') for p in imports)
                or any(a.get('package', {}).get('name') != 'golang.org/x/crypto' for a in affected)):
            raise RuntimeError('Go advisory scope changed or could not be verified')
        proof = {'status': 'not_affected', 'justification': 'vulnerable_code_not_present',
                 'vulnerability': 'GO-2026-5932', 'image_id': image_id, 'binary_sha256': fingerprint,
                 'crypto_version': version, 'scanner_image_id': tool_id,
                 'verified_at_utc': datetime.now(timezone.utc).isoformat(),
                 'evidence': str(destination), 'affected_packages': imports,
                 'reason': 'Compiler dependency inventory and fresh binary analysis confirm OpenPGP packages are absent.'}
        (destination / 'proof.json').write_text(json.dumps(proof, indent=2) + '\n')
        return proof


def image_scan_input(reference):
    details = json.loads(run(['docker', 'image', 'inspect', reference], capture=True).stdout)[0]
    image_id = details.get('Id', '')
    if not re.fullmatch(r'sha256:[a-f0-9]{64}', image_id):
        raise RuntimeError('Image scan requires an immutable local image')
    if re.fullmatch(r'[a-z0-9][a-z0-9./:_-]*@sha256:[a-f0-9]{64}', reference):
        if reference not in (details.get('RepoDigests') or []):
            raise RuntimeError('Registry scan digest does not identify the pulled image')
        if details.get('Os') != 'linux' or details.get('Architecture') != 'amd64':
            raise RuntimeError('Registry qualification requires the reviewed Linux AMD64 image')
        # Containerd-backed Docker can expose a manifest ID instead of a config ID.
        # Registry scanning avoids its incomplete OCI export; verify both identities.
        manifest = json.loads(run(['docker', 'buildx', 'imagetools', 'inspect', '--raw', reference],
                                  capture=True).stdout)
        config_id = manifest.get('config', {}).get('digest', '')
        if not re.fullmatch(r'sha256:[a-f0-9]{64}', config_id):
            raise RuntimeError('Registry qualification requires a single-platform image manifest')
        manifest_id = reference.split('@', 1)[1]
        if image_id != config_id and (image_id != manifest_id
                or details.get('Descriptor', {}).get('digest') != manifest_id):
            raise RuntimeError('Pulled image identity differs from the selected registry manifest')
        return reference, image_id, ['--image-src', 'remote', '--platform', 'linux/amd64'], config_id
    return image_id, image_id, ['--image-src', 'docker'], None


def image_sbom(reference, report, findings):
    source, _, options, _ = image_scan_input(reference)
    if read_json(findings).get('ArtifactName') != source:
        raise RuntimeError('SBOM input differs from the security-scanned image')
    run([TOOLS / 'trivy', 'image', *options, '--format', 'cyclonedx', '--output', report, source])


def trivy_scan(source, report, *, image=False):
    image_id = None
    config_id = None
    options = []
    if image:
        source, image_id, options, config_id = image_scan_input(str(source))
    args = [TOOLS / 'trivy', 'image' if image else 'fs', '--scanners',
            'vuln,secret' if image else 'vuln,misconfig,secret', '--severity', SEVERITIES,
            '--ignore-unfixed=false', '--config', ROOT / 'security/trivy.yaml',
            '--ignorefile', ROOT / 'security/empty.ignore', '--no-progress', '--list-all-pkgs',
            '--timeout', '15m', '--format', 'json', '--output', report]
    if not image:
        args += ['--include-dev-deps']
    args += [*options, source]
    run(args)
    data = read_json(report)
    if image and (data.get('ArtifactName') != source or config_id is not None and (
            data.get('Metadata', {}).get('ImageID') != config_id
            or source not in (data.get('Metadata', {}).get('RepoDigests') or []))):
        raise RuntimeError('Scanner inventory does not match the selected immutable image')
    for result in data.get('Results', []):
        for secret in result.get('Secrets', []):
            secret['Match'] = '[REDACTED]'
            secret.pop('Code', None)
    report.write_text(json.dumps(data, indent=2) + '\n')
    if image and not any(result.get('Packages') for result in data.get('Results', [])):
        raise RuntimeError('Trivy detected no packages in the container image')
    if not image:
        for dependency_file in read_json(Path(source) / 'security/project.json')['dependency_files']:
            if not any(result.get('Packages') and result.get('Target') == dependency_file
                       for result in data.get('Results', [])):
                raise RuntimeError(f'Trivy did not analyze dependencies from {dependency_file}')
    count = 0
    for result in data.get('Results', []):
        target = result['Target']
        for item in result.get('Vulnerabilities', []):
            if item['VulnerabilityID'] == 'GO-2026-5932' and item['PkgName'] == 'golang.org/x/crypto':
                destination = report.parent / (report.stem + '-go-' + hashlib.sha256(target.encode()).hexdigest()[:12])
                if image and result.get('Type') == 'gobinary':
                    proof = verify_openpgp_absent(image_id, '/' + target.lstrip('/'), item['InstalledVersion'], destination)
                elif not image and result.get('Type') == 'gomod':
                    context = str(Path(target).parent)
                    declaration = next((i for i in read_json(Path(source) / 'security/project.json')['images']
                                        if i.get('go_binary') and i['context'] == context), None)
                    if not declaration:
                        raise RuntimeError('Go module finding has no declared binary package verification')
                    tag = f'boxeu-security/go-proof:{os.getpid()}'
                    try:
                        build_image(Path(source), declaration, tag)
                        proof = verify_openpgp_absent(tag, declaration['go_binary'], item['InstalledVersion'], destination)
                    finally:
                        run(['docker', 'image', 'rm', tag], capture=True, accepted=(0, 1))
                else:
                    proof = None
                if proof:
                    item['BoxEUAnalysis'] = proof
                    print(f'  VERIFIED NOT AFFECTED {item["VulnerabilityID"]}: OpenPGP packages absent; evidence {destination}')
                    continue
            count += 1
            print(f'  {item["Severity"]} {item["VulnerabilityID"]} {item["PkgName"]} '
                  f'{item["InstalledVersion"]} -> {item.get("FixedVersion") or "no fix published"}')
        for item in result.get('Misconfigurations', []) + result.get('Secrets', []):
            count += 1
            print(f'  {item["Severity"]} {item.get("ID", item.get("RuleID", "SECRET"))} {target}')
    report.write_text(json.dumps(data, indent=2) + '\n')
    return count


def sast(source, report, spec):
    if not shutil.which('docker'):
        raise RuntimeError('Docker is required for the pinned local Semgrep scanner')
    run(['docker', 'run', '--rm', '--network=none', '--cap-drop=ALL',
         '--security-opt=no-new-privileges', '--read-only', '--tmpfs', '/tmp:rw,nosuid,size=1g',
         '--user', f'{os.getuid()}:{os.getgid()}', '-e', 'HOME=/tmp', '-e', 'SEMGREP_SEND_METRICS=off',
         '-v', f'{source}:/src:ro', '-v', f'{report.parent}:/reports:rw', '-w', '/src',
         spec['semgrep_image'], 'semgrep', 'scan', '--oss-only', '--metrics=off', '--disable-nosem',
         '--strict', '--error', '--disable-version-check', '--no-git-ignore', '--max-target-bytes=0',
         '--timeout=30', '--timeout-threshold=1',
         '--config', '/src/security/semgrep-rules', '--json', '--output', f'/reports/{report.name}', '/src'],
        capture=True, accepted=(0, 1))
    data = read_json(report)
    for item in data.get('results', []):
        for field in ('lines', 'metavars', 'dataflow_trace'):
            item.get('extra', {}).pop(field, None)
    report.write_text(json.dumps(data, indent=2) + '\n')
    if data.get('errors'):
        raise RuntimeError(f'Semgrep reported {len(data["errors"])} scan errors; see private report')
    if not data.get('paths', {}).get('scanned') and (source / 'src').exists():
        raise RuntimeError('Semgrep scanned no source files')
    scanned = set(data.get('paths', {}).get('scanned', []))
    expected = [p for p in (source / 'src').rglob('*') if p.is_file()
                and p.suffix in ('.java', '.js', '.jsx', '.ts', '.tsx', '.mjs', '.cjs')
                and not p.name.endswith('.d.ts') and not str(p.relative_to(source)).startswith('src/test/')]
    missing = [str(p.relative_to(source)) for p in expected
               if '/src/' + str(p.relative_to(source)) not in scanned]
    if missing:
        raise RuntimeError(f'Semgrep skipped {len(missing)} production source files; first: {missing[0]}')
    for item in data['results']:
        print(f'  SAST {item["check_id"]} {item["path"]}:{item["start"]["line"]}')
    return len(data['results'])


def workflow_check(source, report):
    files = sorted((source / '.github/workflows').glob('*.y*ml'))
    if not files:
        raise RuntimeError('No GitHub workflow found for security enforcement')
    result = run([TOOLS / 'actionlint', '-shellcheck=', *files], cwd=source,
                 capture=True, accepted=(0, 1))
    report.write_text((result.stdout or '') + (result.stderr or ''))
    if result.returncode:
        raise RuntimeError('Invalid GitHub Actions workflow; see private actionlint report')
    return 0


def scan(spec, *, revision=None, source_only=False, keep_images=False):
    report_name = revision or ('working-tree-source' if source_only else 'working-tree')
    report = STATE / 'reports' / report_name
    report.mkdir(parents=True, exist_ok=True)
    # An interrupted or early failed scan must never leave an old green summary
    # attached to partly refreshed reports.
    for name in ('summary.json', 'source.json', 'secrets.json', 'history.json', 'semgrep.json', 'actionlint.txt'):
        (report / name).unlink(missing_ok=True)
    for path in report.glob('image-*.json'):
        path.unlink()
    (report / 'summary.json').write_text(json.dumps({'findings': 0,
        'scan_errors': ['Scan did not complete; repair the reported failure and rerun the gate.'],
        'scanned_at_utc': datetime.now(timezone.utc).isoformat(), 'revision': revision or 'working-tree',
        'scope': 'source-only' if source_only else 'source-and-images',
        'image_scans_requested': 0, 'image_scans_completed': 0, 'image_reports': [], 'passed': False}, indent=2) + '\n')
    with tempfile.TemporaryDirectory(prefix='boxeu-security-') as temporary:
        source = Path(temporary) / 'source'
        source.mkdir()
        export_source(source, revision)
        project = read_json(source / 'security/project.json')
        for name in project['dependency_files']:
            if not (source / name).is_file():
                raise RuntimeError(f'Missing dependency lockfile: {name}')
        # No scanner-specific silent bypasses. Policy changes must remain reviewable.
        for name in ('.trivyignore', '.trivyignore.yaml', '.gitleaksignore', '.semgrepignore'):
            if (source / name).exists():
                raise RuntimeError(f'Unreviewed scanner exclusion file: {name}')
        for path in source.rglob('*'):
            if path.is_file() and path.suffix in ('.java', '.ts', '.tsx', '.js', '.jsx', '.yml', '.yaml', '.sh'):
                if re.search(r'trivy\s*:\s*ignore', path.read_text(errors='replace'), re.IGNORECASE):
                    raise RuntimeError(f'Inline Trivy exclusion requires review: {path.relative_to(source)}')
        failures = []
        total = 0
        checks = [
            ('secrets in files', lambda: secret_scan(source, report / 'secrets.json')),
            ('secrets in Git history', lambda: secret_scan(source, report / 'history.json', revision=revision or '--all')),
            ('dependencies and configuration', lambda: trivy_scan(source, report / 'source.json')),
            ('source code', lambda: sast(source, report / 'semgrep.json', spec)),
            ('GitHub workflows', lambda: workflow_check(source, report / 'actionlint.txt'))
        ]
        for title, check in checks:
            print(f'Checking {title}...', flush=True)
            try:
                total += check()
            except (RuntimeError, OSError, ValueError) as error:
                failures.append(f'{title}: {error}')
        images_completed = 0
        image_reports = []
        image_records = []
        if not source_only:
            for index, image in enumerate(project['images']):
                tag = f'boxeu-security/{ROOT.name}:{os.getpid()}-{index}'
                try:
                    print(f'Building and scanning {image["name"]} image...', flush=True)
                    build_image(source, image, tag)
                    total += trivy_scan(tag, report / f'image-{index}.json', image=True)
                    images_completed += 1
                    image_reports.append(f'image-{index}.json')
                    image_sbom(tag, report / f'image-{index}.cdx.json', report / f'image-{index}.json')
                    image_records.append({'name': image['name'], 'image_id':
                        run(['docker', 'image', 'inspect', '--format', '{{.Id}}', tag], capture=True).stdout.strip()})
                except (RuntimeError, OSError, ValueError) as error:
                    failures.append(f'{image["name"]} image: {error}')
                finally:
                    if not keep_images:
                        run(['docker', 'image', 'rm', tag], capture=True, accepted=(0, 1))
        print(f'Private security reports: {report}')
        (report / 'summary.json').write_text(json.dumps({'findings': total, 'scan_errors': failures,
            'scanned_at_utc': datetime.now(timezone.utc).isoformat(), 'revision': revision or 'working-tree',
            'scope': 'source-only' if source_only else 'source-and-images',
            'image_scans_requested': 0 if source_only else len(project['images']),
            'image_scans_completed': images_completed, 'image_reports': image_reports,
            'image_records': image_records,
            'passed': not total and not failures}, indent=2) + '\n')
        for failure in failures:
            print(f'  SCAN ERROR: {failure}', file=sys.stderr)
        if total or failures:
            raise RuntimeError(f'Security gate BLOCKED: {total} findings, {len(failures)} scan errors')
        print('Security gate PASSED')


def install_hooks():
    current = run(['git', 'config', '--get', 'core.hooksPath'], capture=True, accepted=(0, 1)).stdout.strip()
    if current and current != '.githooks':
        raise RuntimeError(f'Existing hooksPath {current!r}; integrate hooks manually without replacing it')
    default = Path(run(['git', 'rev-parse', '--git-path', 'hooks'], capture=True).stdout.strip())
    if not current and any((default / name).exists() for name in ('pre-commit', 'pre-push')):
        raise RuntimeError('Existing Git hooks; integrate manually without replacing them')
    for path in (ROOT / '.githooks').iterdir():
        path.chmod(0o755)
    run(['git', 'config', '--local', 'core.hooksPath', '.githooks'])
    print('Local pre-commit and pre-push hooks installed')


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['setup', 'scan', 'staged', 'pre-push', 'image'])
    parser.add_argument('--source-only', action='store_true')
    parser.add_argument('--install-hooks', action='store_true')
    parser.add_argument('--target')
    parser.add_argument('--keep-images', action='store_true',
                        help='Retain this run\'s scanned platform images for configuration validation')
    args = parser.parse_args()
    if args.keep_images and (args.command != 'scan' or args.source_only):
        raise RuntimeError('--keep-images requires a complete scan')
    STATE.mkdir(parents=True, exist_ok=True)
    STATE.chmod(0o700)
    # Keep reports and shared per-repository scanner files consistent across IDE/hooks/CI calls.
    lock = (STATE / 'gate.lock').open('a')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print('Waiting for the running security check in this repository...', flush=True)
        fcntl.flock(lock, fcntl.LOCK_EX)
    spec = provision()
    if args.command == 'setup':
        run(['docker', 'pull', spec['semgrep_image']])
        if args.install_hooks:
            install_hooks()
    elif args.command == 'staged':
        with tempfile.TemporaryDirectory(prefix='boxeu-security-index-') as directory:
            source = Path(directory)
            export_source(source, staged=True)
            report = STATE / 'staged-secrets.json'
            if secret_scan(source, report):
                raise RuntimeError('Commit blocked: staged secrets detected')
    elif args.command == 'image':
        if not args.target:
            raise RuntimeError('image requires --target')
        report = STATE / 'reports/image'
        report.mkdir(parents=True, exist_ok=True)
        if trivy_scan(args.target, report / 'trivy.json', image=True):
            raise RuntimeError('Image blocked: security findings detected')
        image_sbom(args.target, report / 'sbom.cdx.json', report / 'trivy.json')
    elif args.command == 'pre-push':
        revisions = []
        for line in sys.stdin:
            _, revision, _, _ = line.split()
            if set(revision) == {'0'}:
                continue
            commit = run(['git', 'rev-parse', '--verify', f'{revision}^{{commit}}'], capture=True).stdout.strip()
            if commit not in revisions:
                revisions.append(commit)
        for revision in revisions:
            scan(spec, revision=revision)
    else:
        scan(spec, source_only=args.source_only, keep_images=args.keep_images)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.CalledProcessError) as failure:
        print(f'SECURITY BLOCKED: {failure}', file=sys.stderr)
        sys.exit(1)
