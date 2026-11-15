#!/usr/bin/env python3
"""Check the live TLS and Access boundary; no credentials are required.

This checks signed-out and forged-session denial, not a user's signed-in session
or the health of the protected applications. Run after publishing DNS.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


# Hosts whose app is its own gate (Better Auth), not Cloudflare Access. Signed
# out, the page must redirect to the app's sign-in and the API must answer 401.
# Sortarr is behind Access while Kyle is its only user; when it leaves Access, add:
#   'sortarr.thescudders.org': {'/': '/auth/sign-in', '/api/library': 401}
APP_GATED = {}


def check_app_gate(hostname, path, expected):
    request = urllib.request.Request('https://' + hostname + path,
                                     headers={'User-Agent': 'UDMS-Access-verification/1.0'})
    result = {'hostname': hostname, 'path': path, 'forged_session': False}
    try:
        opener = urllib.request.build_opener(NoRedirect())
        try:
            response = opener.open(request, timeout=20)
        except urllib.error.HTTPError as response_error:
            response = response_error
        with response:
            location = urllib.parse.urlparse(response.headers.get('Location', ''))
            result.update(status=response.code, redirect_path=location.path)
            result['passed'] = (response.code == expected if isinstance(expected, int)
                                else response.code in (302, 303, 307) and location.path == expected)
    except Exception as exc:
        result.update(passed=False, error=type(exc).__name__)
    return result


def check(scenario):
    hostname, path, forged_session = scenario
    headers = {'User-Agent': 'UDMS-Access-verification/1.0'}
    if forged_session:
        headers['Cookie'] = 'CF_Authorization=invalid-verification-session'
    request = urllib.request.Request('https://' + hostname + path, headers=headers)
    result = {'hostname': hostname, 'path': path, 'forged_session': forged_session}
    try:
        opener = urllib.request.build_opener(NoRedirect())
        try:
            response = opener.open(request, timeout=20)
        except urllib.error.HTTPError as response_error:
            response = response_error
        with response:
            status = response.code
            location = urllib.parse.urlparse(response.headers.get('Location', ''))
            result.update(status=status, redirect_host=location.hostname)
            # A 200 from an unprotected origin or an edge error must fail.
            result['passed'] = (
                status == 302
                and location.scheme == 'https'
                and location.hostname == 'kylescudder.cloudflareaccess.com'
                and location.path.startswith('/cdn-cgi/access/login/')
            )
    except Exception as exc:
        result.update(passed=False, error=type(exc).__name__)
    return result


def check_origin(rule):
    """Request the origin with the Host header the tunnel sends; apps may reject it."""
    host = rule.get('originRequest', {}).get('httpHostHeader', rule['hostname'])
    cmd = ['docker', '--context', 'colima', 'exec', 'radarr', 'curl', '--silent',
           '--max-time', '10', '--header', 'Host: ' + host,
           '--write-out', '\n%{http_code}', rule['service'] + '/']
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20).stdout
    except Exception as exc:
        return {'hostname': rule['hostname'], 'passed': False, 'error': type(exc).__name__}
    body, _, status = out.rpartition('\n')
    # Lidarr is known to be down (000); reject only app-level hostname rejections.
    rejected = 'invalid hostname' in body.lower() or status == '400'
    return {'hostname': rule['hostname'], 'forwarded_host': host, 'status': status,
            'passed': not rejected}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    config = json.loads((Path(__file__).parent / 'cloudflare/ingress.json').read_text())
    hosts = [rule['hostname'] for rule in config['ingress']
             if 'hostname' in rule and rule['hostname'] not in APP_GATED]
    scenarios = [(host, path, forged) for host in hosts
                 for path, forged in [('/', False), ('/api/v3/system/status', False), ('/', True)]]
    with ThreadPoolExecutor(max_workers=6) as pool:
        results = list(pool.map(check, scenarios))
    for result in results:
        print(('PASS' if result['passed'] else 'FAIL') + ' ' + result['hostname']
              + result['path'] + (' (forged session)' if result['forged_session'] else ' (signed out)'))
    for host, paths in APP_GATED.items():
        for path, expected in paths.items():
            result = check_app_gate(host, path, expected)
            print(('PASS' if result['passed'] else 'FAIL') + ' ' + host + path + ' (app sign-in gate)')
            results.append(result)
    origin_results = [check_origin(rule) for rule in config['ingress'] if 'hostname' in rule]
    for result in origin_results:
        print(('PASS' if result['passed'] else 'FAIL') + ' ' + result['hostname']
              + ' (origin accepts forwarded Host)')
    results += origin_results
    passed = sum(result['passed'] for result in results)
    report = {'observed_at': datetime.now(timezone.utc).isoformat(),
              'command': 'python3 udms/verify-cloudflare.py',
              'passed': passed, 'failed': len(results) - passed, 'results': results,
              'limitations': ['Does not verify interactive sign-in or full protected origin health.']}
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(f'{passed}/{len(results)} live Access checks passed')
    return 0 if passed == len(results) else 1


if __name__ == '__main__':
    sys.exit(main())
