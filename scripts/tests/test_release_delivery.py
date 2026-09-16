import importlib.util
from pathlib import Path
import plistlib
import tempfile
import unittest
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
