#!/usr/bin/env python3
"""Readable local reports. Never print matched credentials or source-code snippets."""
import argparse
from collections import Counter
import fcntl
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REPOSITORIES = ('boxeudelivery-backend', 'boxeudelivery-ui', 'boxeudelivery-db-migrations',
                'boxeudelivery-infrastructure', 'backend-boxeu', 'frontend-boxeu', 'db-boxeu', 'boxeudelivery-knoweledge')
PRIORITY = {'CRITICAL': 0, 'HIGH': 1, 'MEDIUM': 2, 'LOW': 3, 'UNKNOWN': 4}


def load(path):
    return json.loads(path.read_text())


def describe(root):
    state = root / '.local/security'
    if not state.exists():
        return [f'{root.name}: NOT SCANNED'], []
    with (state / 'gate.lock').open('a') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return [f'{root.name}: SCAN IN PROGRESS'], []
        report = state / 'reports/working-tree'
        summary = report / 'summary.json'
        if not summary.exists():
            report = state / 'reports/working-tree-source'
            summary = report / 'summary.json'
        if not summary.exists():
            return [f'{root.name}: NO COMPLETED WORKING-TREE SCAN'], []
        data = load(summary)
        lines = [f'{root.name}: {"PASSED" if data["passed"] else "BLOCKED"}',
                 f'  Scope: {data.get("scope", "source and image scan; see image count")}',
                 f'  Recorded findings: {data["findings"]}; scanner errors: {len(data["scan_errors"])}',
                 f'  Images: {data.get("image_scans_completed", 0)}/{data.get("image_scans_requested", 0)}',
                 f'  Scan time (UTC): {data.get("scanned_at_utc", "see report file timestamp")}']
        rows = []
        names = ['source.json'] + data.get('image_reports',
            [f'image-{i}.json' for i in range(data.get('image_scans_completed', 0))])
        for name in names:
            path = report / name
            if not path.exists():
                continue
            for result in load(path).get('Results', []):
                target = result['Target']
                for item in result.get('Vulnerabilities', []):
                    if item.get('BoxEUAnalysis', {}).get('status') == 'not_affected':
                        rows.append(('NOT_AFFECTED', item['VulnerabilityID'], item['PkgName'],
                                     item['InstalledVersion'], item['BoxEUAnalysis']['reason'],
                                     item['BoxEUAnalysis']['evidence']))
                        continue
                    rows.append((item['Severity'], item['VulnerabilityID'], item['PkgName'],
                                 item['InstalledVersion'], item.get('FixedVersion') or 'NO PUBLISHED FIX', target))
                for item in result.get('Misconfigurations', []):
                    rows.append((item['Severity'], item['ID'], item['Title'], '', 'configuration review', target))
                for item in result.get('Secrets', []):
                    rows.append((item['Severity'], item['RuleID'], 'credential detected', '', 'remove/rotate credential', target))
        for name in ('secrets.json', 'history.json'):
            path = report / name
            if path.exists():
                for item in load(path):
                    rows.append(('HIGH', item['RuleID'], 'credential detected', '', 'remove/rotate credential',
                                 f'{item["File"]}:{item["StartLine"]} ({name})'))
        path = report / 'semgrep.json'
        if path.exists():
            for item in load(path).get('results', []):
                rows.append(('HIGH', item['check_id'], 'source security finding', '', 'source review',
                             f'{item["path"]}:{item["start"]["line"]}'))
        for error in data['scan_errors']:
            rows.append(('HIGH', 'SCAN ERROR', error, '', 'repair and rescan', 'scanner'))
        lines.append('  Severity/status occurrences: ' + (', '.join(f'{k}={v}' for k, v in Counter(r[0] for r in rows).items()) or 'none'))
        return lines, sorted(set(rows), key=lambda r: (PRIORITY.get(r[0], 9), r[2], r[1], r[5]))


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--workspace', action='store_true', help='Include available sibling BoxEU repositories')
args = parser.parse_args()
roots = [ROOT.parent / name for name in REPOSITORIES if (ROOT.parent / name / '.git').exists()] if args.workspace else [ROOT]
lines = ['BoxEU security findings', '',
         'This report records completed scans; check the timestamp before relying on it.',
         'All severities, unfixed advisories and scanner failures remain blocking.',
         'NOT_AFFECTED requires fresh evidence that the advisory packages are absent from the exact scanned binary.',
         'Repeated advisories in different packages/images are separate recorded occurrences.', '']
details = []
for root in roots:
    summary, rows = describe(root)
    lines.extend(summary + [''])
    if rows:
        details.extend([root.name, '-' * len(root.name)])
        for severity, identifier, subject, installed, fixed, target in rows:
            details.append(f'[{severity}] {identifier} | {subject} | {installed} -> {fixed} | {target}')
        details.append('')
lines.extend(['Detailed findings', '=================', ''] + details)
print('\n'.join(lines))
