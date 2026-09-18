import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import plistlib
import tempfile
import unittest
import urllib.error
import urllib.request
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('delivery', Path(__file__).parents[1] / 'verify_release_delivery.py')
delivery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(delivery)


class DeliveryTests(unittest.TestCase):
    def setUp(self):
        self.url = f'https://github.com/{delivery.REPO}/releases/download/v0.1.9/Revclip-v0.1.9.dmg'
        self.release = {'tag_name': 'v0.1.9', 'draft': False, 'prerelease': False, 'assets': [
            {'name': 'appcast.xml'}, {'name': 'Revclip-v0.1.9.dmg', 'size': 123, 'browser_download_url': self.url}]}
        self.feed = f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>42</sparkle:version><sparkle:shortVersionString>0.1.9</sparkle:shortVersionString>
        <enclosure url="{self.url}" length="123" sparkle:edSignature="test-only"/>
        </item></channel></rss>'''

    def check(self, feed=None):
        return delivery.verify_feed(feed or self.feed, 'v0.1.9', '42', self.release)

    def test_matching_published_version(self):
        self.assertEqual(self.check()[:2], (self.url, 123))

    def test_previous_release_is_not_success(self):
        self.release['tag_name'] = 'v0.1.8'
        with self.assertRaisesRegex(ValueError, 'Latest public release'):
            self.check()

    def test_stale_feed_build(self):
        with self.assertRaisesRegex(ValueError, 'build'):
            self.check(self.feed.replace('>42<', '>41<'))

    def test_stale_feed_marketing_version(self):
        with self.assertRaisesRegex(ValueError, 'version'):
            self.check(self.feed.replace('>0.1.9<', '>0.1.8<'))

    def test_wrong_download_url(self):
        with self.assertRaisesRegex(ValueError, 'URL'):
            self.check(self.feed.replace(self.url, 'https://example.invalid/old.dmg'))

    def test_artifact_size_mismatch(self):
        self.release['assets'][1]['size'] = 122
        with self.assertRaisesRegex(ValueError, 'differ'):
            self.check()

    def test_unsigned_feed(self):
        with self.assertRaisesRegex(ValueError, 'signature'):
            self.check(self.feed.replace('sparkle:edSignature="test-only"', ''))

    def test_prerelease_not_stable(self):
        self.release['prerelease'] = True
        with self.assertRaisesRegex(ValueError, 'stable/public'):
            self.check()

    def test_installed_demo_forgotten_and_feed_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / 'revclip-demo.app'
            contents = app / 'Contents'
            (contents / 'MacOS').mkdir(parents=True)
            (contents / 'MacOS/fixture').write_bytes(b'synthetic executable')
            info = {'CFBundleIdentifier': 'com.revclip.revclip-demo', 'CFBundleExecutable': 'fixture',
                    'CFBundleShortVersionString': '0.1.8', 'CFBundleVersion': '41', 'SUFeedURL': ''}
            def save():
                (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
            save()
            with self.assertRaisesRegex(ValueError, 'version/build'):
                delivery.verify_app(app, 'v0.1.9', '42', True)
            info.update(CFBundleShortVersionString='0.1.9', CFBundleVersion='42')
            save()
            self.assertEqual(delivery.verify_app(app, 'v0.1.9', '42', True)['build'], '42')
            info['SUFeedURL'] = 'https://example.invalid/production-feed'
            save()
            with self.assertRaisesRegex(ValueError, 'update feed'):
                delivery.verify_app(app, 'v0.1.9', '42', True)

    def test_failure_removes_stale_pass_receipt(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'receipt.json'
            output.write_text('{"status":"passed"}')
            argv = ['verify_release_delivery.py', '--tag', 'v0.1.9', '--build', '42',
                    '--sha', 'a' * 40, '--output', str(output)]
            with patch('sys.argv', argv), patch.object(delivery, 'public_tag_sha', return_value='b' * 40):
                with self.assertRaisesRegex(ValueError, 'different commit'):
                    delivery.main()
            self.assertFalse(output.exists())

    def test_cannot_verify_only_one_installed_app(self):
        argv = ['verify_release_delivery.py', '--tag', 'v0.1.9', '--build', '42',
                '--sha', 'a' * 40, '--output', 'unused.json', '--app', 'fixture.app']
        with patch('sys.argv', argv), patch.object(delivery, 'public_tag_sha') as network:
            with self.assertRaisesRegex(ValueError, 'both installed apps'):
                delivery.main()
            network.assert_not_called()


TOKEN = 'ghs_test-only_0123456789'


class FakeResponse(io.BytesIO):
    def __enter__(self):
        return self

    def __exit__(self, *unused):
        self.close()


class TokenScopeTests(unittest.TestCase):
    """The optional token reaches the GitHub API only; delivery is checked anonymously."""

    def run_main(self, output, environment):
        tag, build, sha = 'v0.1.9', '42', 'a' * 40
        dmg = b'synthetic artifact'
        url = f'https://github.com/{delivery.REPO}/releases/download/{tag}/Revclip-{tag}.dmg'
        release = {'tag_name': tag, 'draft': False, 'prerelease': False, 'html_url': 'https://example.invalid/r',
                   'assets': [{'name': 'appcast.xml'},
                              {'name': f'Revclip-{tag}.dmg', 'size': len(dmg), 'browser_download_url': url,
                               'digest': 'sha256:' + hashlib.sha256(dmg).hexdigest()}]}
        feed = f'''<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>
        <sparkle:version>{build}</sparkle:version><sparkle:shortVersionString>0.1.9</sparkle:shortVersionString>
        <enclosure url="{url}" length="{len(dmg)}" sparkle:edSignature="test-only"/></item></channel></rss>'''
        api = f'https://api.github.com/repos/{delivery.REPO}'
        bodies = {f'{api}/git/ref/tags/{tag}': json.dumps({'object': {'type': 'commit', 'sha': sha}}).encode(),
                  f'{api}/releases/latest': json.dumps(release).encode(),
                  f'https://github.com/{delivery.REPO}/releases/latest/download/appcast.xml': feed.encode(),
                  url: dmg}
        calls = []

        def urlopen(target, timeout=None):
            request = target if isinstance(target, urllib.request.Request) else urllib.request.Request(target)
            sent = dict(request.header_items())
            calls.append((request.full_url, sent.get('Authorization')))
            return FakeResponse(bodies[request.full_url])

        argv = ['verify_release_delivery.py', '--tag', tag, '--build', build, '--sha', sha, '--output', str(output)]
        printed = io.StringIO()
        with patch('sys.argv', argv), patch.dict(os.environ, environment, clear=False), \
                patch.object(delivery.urllib.request, 'urlopen', urlopen), contextlib.redirect_stdout(printed):
            if 'GITHUB_TOKEN' not in environment:
                os.environ.pop('GITHUB_TOKEN', None)
            delivery.main()
        return calls, printed.getvalue()

    def test_token_goes_to_the_api_only_and_never_into_output(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'receipt.json'
            calls, printed = self.run_main(output, {'GITHUB_TOKEN': TOKEN})
            self.assertEqual(len(calls), 4)
            for url, authorization in calls:
                if url.startswith('https://api.github.com/'):
                    self.assertEqual(authorization, 'Bearer ' + TOKEN)
                else:
                    self.assertIsNone(authorization, url)
            self.assertNotIn(TOKEN, printed)
            self.assertNotIn(TOKEN, output.read_text())
            self.assertEqual(json.loads(output.read_text())['status'], 'passed')

    def test_long_stateless_installation_token_is_opaque_and_api_only(self):
        token = 'ghs_12345_' + 'a' * 180 + '.' + 'b' * 300 + '.' + 'c' * 86
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'delivery.json'
            calls, printed = self.run_main(output, {'GITHUB_TOKEN': token})
            for url, authorization in calls:
                if url.startswith('https://api.github.com/'):
                    self.assertEqual(authorization, 'Bearer ' + token)
                else:
                    self.assertIsNone(authorization)
            self.assertNotIn(token, printed)
            self.assertNotIn(token, output.read_text())

    def test_local_run_without_token_stays_anonymous_and_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            calls, _ = self.run_main(Path(directory) / 'receipt.json', {})
            self.assertEqual([authorization for _, authorization in calls], [None] * 4)

    def test_token_is_not_forwarded_to_a_redirect_target(self):
        request = delivery.api_request(f'https://api.github.com/repos/{delivery.REPO}/releases/latest', TOKEN)
        self.assertNotIn('Authorization', request.headers)
        handler = urllib.request.HTTPRedirectHandler()
        for target in ('https://evil.example/steal', 'https://api.github.com/repositories/1/releases/latest'):
            followed = handler.redirect_request(request, None, 302, 'Found', {}, target)
            self.assertNotIn(TOKEN, repr(followed.header_items()))
            self.assertFalse(followed.has_header('Authorization'))

    def test_only_the_exact_https_api_host_is_an_api_url(self):
        for url in ('http://api.github.com/repos/x', 'https://api.github.com.evil.example/repos/x',
                    'https://api.github.com:444/repos/x', 'https://token@api.github.com/repos/x',
                    'https://API.github.com@evil.example/x', f'https://github.com/{delivery.REPO}/releases/latest'):
            with self.assertRaisesRegex(ValueError, 'Not a GitHub API URL'):
                delivery.api_request(url, TOKEN)

    def test_malformed_token_is_rejected_before_any_request(self):
        with patch.dict(os.environ, {'GITHUB_TOKEN': 'abc\r\nX-Injected: 1'}), \
                patch.object(delivery.urllib.request, 'urlopen') as network:
            with self.assertRaisesRegex(ValueError, 'unexpected form'):
                delivery.fetch_api('https://api.github.com/repos/x')
            network.assert_not_called()

    def test_rate_limit_is_named_without_the_token(self):
        def refuse(target, timeout=None):
            raise urllib.error.HTTPError(target.full_url, 403, 'rate limit exceeded', {}, None)
        with patch.dict(os.environ, {'GITHUB_TOKEN': TOKEN}), patch.object(delivery.urllib.request, 'urlopen', refuse):
            with self.assertRaisesRegex(ValueError, 'HTTP 403') as caught:
                delivery.fetch_api('https://api.github.com/repos/x')
        self.assertNotIn(TOKEN, str(caught.exception))


if __name__ == '__main__':
    unittest.main()
