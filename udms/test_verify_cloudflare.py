"""Offline checks for Listarr's public boundary; never contact deployed services."""
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch
import urllib.error

spec = importlib.util.spec_from_file_location(
    'verify_cloudflare', Path(__file__).with_name('verify-cloudflare.py'))
verify = importlib.util.module_from_spec(spec)
spec.loader.exec_module(verify)


class Response(io.BytesIO):
    def __init__(self, body, status=200, content_type='application/json'):
        super().__init__(body)
        self.code = status
        self.headers = {'Content-Type': content_type}


class PublicBoundaryTests(unittest.TestCase):
    def check(self, path, body, expected=None, status=200, content_type='application/json'):
        with patch.object(verify.urllib.request, 'build_opener') as opener:
            opener.return_value.open.return_value = Response(body, status, content_type)
            result = verify.check_public_app('listarr.thescudders.org', path, expected)
            request = opener.return_value.open.call_args.args[0]
            self.assertFalse(request.has_header('Authorization'))
            self.assertFalse(request.has_header('Cookie'))
            return result['passed']

    def test_public_html(self):
        self.assertTrue(self.check('/', b'<html>Listarr</html>', content_type='text/html'))
        self.assertFalse(self.check('/', b'', content_type='text/html'))

    def test_health_requires_ok_and_revision(self):
        self.assertTrue(self.check('/api/health', b'{"ok":true,"revision":"abc"}'))
        self.assertFalse(self.check('/api/health', b'{"ok":false,"revision":"abc"}'))
        self.assertFalse(self.check('/api/health', b'{"ok":true}'))

    def test_feed_requires_exact_ids(self):
        expected = [{'id': 438631}]
        self.assertTrue(self.check('/api/feed?ids=438631', json.dumps(expected).encode(), expected))
        self.assertFalse(self.check('/api/feed?ids=438631', b'[]', expected))
        self.assertFalse(self.check('/api/feed?ids=438631', b'<html>Sign in</html>', expected))

    def test_access_redirect_is_failure(self):
        with patch.object(verify.urllib.request, 'build_opener') as opener:
            opener.return_value.open.side_effect = urllib.error.HTTPError(
                'https://listarr.thescudders.org/api/feed?ids=438631', 302, 'Found',
                {'Location': 'https://kylescudder.cloudflareaccess.com/cdn-cgi/access/login/'},
                io.BytesIO(b''))
            self.assertFalse(verify.check_public_app(
                'listarr.thescudders.org', '/api/feed?ids=438631', [{'id': 438631}])['passed'])

    def test_upstream_error_is_failure(self):
        self.assertFalse(self.check('/api/health', b'{"ok":true,"revision":"abc"}', status=502))

    def test_network_error_is_failure(self):
        with patch.object(verify.urllib.request, 'build_opener') as opener:
            opener.return_value.open.side_effect = urllib.error.URLError('offline')
            self.assertFalse(verify.check_public_app(
                'listarr.thescudders.org', '/api/health', None)['passed'])


if __name__ == '__main__':
    unittest.main()
