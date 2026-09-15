"""Native CLI integration against synthetic Unix sockets only.

Run after building separately:
    REVCLIP_NATIVE_CLI=build/revclip python3 -m unittest discover \
        -s scripts/tests -p test_native_cli.py -v

No compiler, real app, database, clipboard, report endpoint or installer is used.
setUpClass MUST prove Foundation's temporary-home routing with read-only folders
requests before unittest can enter ANY test, regardless of test name/order/filter.
Agent inspect/install is intentionally left to the installer's isolated tests.
"""
import base64
import json
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid


REQUEST_CAP = 16 * 1024 * 1024
RESPONSE_CAP = 32 * 1024 * 1024
PROCESS_TIMEOUT = 8


def encoded(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False).encode('utf-8')


def framed(value):
    body = encoded(value)
    return struct.pack('!I', len(body)) + body


def read_exact(connection, size):
    result = bytearray()
    while len(result) < size:
        chunk = connection.recv(min(8192, size - len(result)))
        if not chunk:
            raise AssertionError('Native CLI sent an incomplete request frame')
        result.extend(chunk)
    return bytes(result)


class FakeApp:
    """One same-UID 0600 Unix socket, bounded reads, captured exceptions, no backend."""
    def __init__(self, path, response, wire=None, mode=0o600):
        self.path = path
        self.response = response
        self.wire = framed(response) if wire is None else wire
        self.accepted = False
        self.request = None
        self.frame_size = None
        self.errors = []
        self.stopping = threading.Event()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            # Never unlink an existing endpoint, even within the temporary home.
            self.listener.bind(str(path))
            os.chmod(path, mode)
            info = path.lstat()
            assert stat.S_ISSOCK(info.st_mode) and info.st_uid == os.getuid()
            assert stat.S_IMODE(info.st_mode) == mode
            self.listener.listen(1)
            self.listener.settimeout(0.05)
        except BaseException:
            self.listener.close()
            raise
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def _serve(self):
        try:
            # Drain a queued connection even if the process exited before accept.
            while True:
                try:
                    connection, _ = self.listener.accept()
                    break
                except socket.timeout:
                    if self.stopping.is_set():
                        return
            self.accepted = True
            with connection:
                connection.settimeout(3)
                self.frame_size = struct.unpack('!I', read_exact(connection, 4))[0]
                if not 0 < self.frame_size <= REQUEST_CAP:
                    raise AssertionError('Native CLI violated request framing limit')
                self.request = json.loads(read_exact(connection, self.frame_size))
                # Deliberately fragment both the length prefix and JSON body.
                # Brief separation exercises clients that wrongly assume recv(n)
                # always returns n; later chunks avoid slow large-response tests.
                boundaries = [1, 2, 3, 4, 5, 8, 13, len(self.wire)]
                start = 0
                for end in boundaries:
                    end = min(end, len(self.wire))
                    if end <= start:
                        continue
                    try:
                        connection.sendall(self.wire[start:end])
                    except (BrokenPipeError, ConnectionResetError):
                        # Expected when the client rejects an invalid length/header.
                        break
                    start = end
                    if end < min(13, len(self.wire)):
                        time.sleep(0.002)
        except BaseException as error:
            self.errors.append(error)

    def __exit__(self, exc_type, exc_value, traceback):
        self.stopping.set()
        self.thread.join(4)
        self.listener.close()
        if self.thread.is_alive():
            raise AssertionError('Fake socket thread failed to finish')
        self.path.unlink(missing_ok=True)
        if exc_type is None and self.errors:
            raise AssertionError('Fake app failed') from self.errors[0]


@unittest.skipUnless(sys.platform == 'darwin', 'Foundation native CLI requires macOS')
class NativeCLIIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        configured = os.environ.get('REVCLIP_NATIVE_CLI')
        if not configured:
            raise RuntimeError('Set REVCLIP_NATIVE_CLI to the already-built native executable; this suite never builds it')
        cls.binary = Path(configured).expanduser().resolve(strict=True)
        info = cls.binary.stat()
        if not stat.S_ISREG(info.st_mode) or not os.access(cls.binary, os.X_OK) or info.st_mode & (stat.S_ISUID | stat.S_ISGID):
            raise RuntimeError('REVCLIP_NATIVE_CLI must be a regular executable without setuid/setgid')
        cls.binary_identity = (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)
        with cls.binary.open('rb') as stream:
            magic = stream.read(4)
        if magic not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe',
                         b'\xbe\xba\xfe\xca', b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'):
            raise RuntimeError('Expected Mach-O native binary, not a Python/shell wrapper')
        # /tmp keeps sockaddr_un paths below macOS's 104-byte sun_path ceiling.
        cls.temporary = tempfile.TemporaryDirectory(prefix='rccli-', dir='/tmp')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.home = Path(cls.temporary.name).resolve()
        os.chmod(cls.home, 0o700)
        cls.empty_bin = cls.home / 'empty-bin'
        cls.empty_bin.mkdir(mode=0o700)
        cls.sockets = {}
        for app in ('Revclip', 'revclip-demo'):
            directory = cls.home / 'Library' / 'Application Support' / app
            directory.mkdir(parents=True, mode=0o700)
            cls.sockets[app] = directory / 'cli.sock'
            if len(os.fsencode(cls.sockets[app])) >= 104:
                raise RuntimeError('Temporary socket path exceeds macOS limit')
        # Construct a child-only environment; never change the test process HOME.
        # Empty PATH proves transport commands cannot depend on python/external tools.
        cls.child_env = {
            'HOME': str(cls.home), 'CFFIXED_USER_HOME': str(cls.home),
            'TMPDIR': str(cls.home), 'PATH': str(cls.empty_bin), 'LANG': 'en_US.UTF-8',
        }
        cls.isolation_proven = False
        # FAILURE HERE is a class setup ERROR: no mutation/bug-report tests run.
        probes = [(['folders'], 'Revclip'),
                  (['--app', 'Revclip', 'folders'], 'Revclip'),
                  (['folders', '--app', 'Revclip'], 'Revclip'),
                  (['--app', 'revclip-demo', 'folders'], 'revclip-demo'),
                  (['folders', '--app=revclip-demo'], 'revclip-demo')]
        for arguments, app in probes:
            sentinel = {'ok': True, 'result': {'temporary_socket_proof': uuid.uuid4().hex}}
            with FakeApp(cls.sockets[app], sentinel) as server:
                completed = cls._process(arguments)
            if (completed.returncode != 0 or not server.accepted or
                    server.request != {'op': 'folders'} or
                    cls._decode(completed) != sentinel):
                raise RuntimeError('ISOLATION NOT PROVEN: folders did not reach the temporary fake socket; all remaining tests aborted')
        cls.isolation_proven = True

    @classmethod
    def _process(cls, arguments, input_bytes=b''):
        if cls.child_env.get('HOME') != str(cls.home) or cls.child_env.get('CFFIXED_USER_HOME') != str(cls.home):
            raise AssertionError('Temporary-home environment was altered')
        info = cls.binary.stat()
        if (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns) != cls.binary_identity:
            raise AssertionError('Native binary changed after isolation setup; aborting instead of trusting an unproven executable')
        return subprocess.run([str(cls.binary), *map(str, arguments)], input=input_bytes,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              env=dict(cls.child_env), cwd=cls.home,
                              timeout=PROCESS_TIMEOUT, check=False)

    @staticmethod
    def _decode(completed):
        try:
            response = json.loads(completed.stdout.decode('utf-8'))
        except (UnicodeError, ValueError) as error:
            raise AssertionError('Native CLI stdout must contain exactly one UTF-8 JSON response') from error
        if not isinstance(response, dict) or type(response.get('ok')) is not bool:
            raise AssertionError('Native CLI response must be an object with strict boolean ok')
        return response

    def invoke(self, arguments, *, app='Revclip', input_bytes=b'', response=None, wire=None, mode=0o600):
        self.assertTrue(type(self).isolation_proven, 'Refusing to launch without proven temporary socket routing')
        if response is None:
            response = {'ok': True, 'result': {'synthetic': True}}
        with FakeApp(self.sockets[app], response, wire=wire, mode=mode) as server:
            completed = self._process(arguments, input_bytes)
        return completed, self._decode(completed), server

    def assert_request(self, arguments, expected, **kwargs):
        completed, response, server = self.invoke(arguments, **kwargs)
        self.assertEqual(completed.returncode, 0, response)
        self.assertIs(response['ok'], True)
        self.assertTrue(server.accepted)
        self.assertEqual(server.request, expected)
        return response

    def assert_rejected(self, arguments, *, code=1, **kwargs):
        completed, response, server = self.invoke(arguments, **kwargs)
        self.assertEqual(completed.returncode, code, response)
        self.assertIs(response['ok'], False)
        self.assertIsInstance(response.get('error'), str)
        self.assertFalse(server.accepted, 'Invalid input must fail before connecting')
        return response

    def file(self, data, name=None):
        path = self.home / (name or ('fixture-' + uuid.uuid4().hex))
        with path.open('xb') as stream:
            stream.write(data)
        return path

    def test_all_transport_commands_emit_exact_request_json(self):
        cases = [
            (['folders'], {'op': 'folders'}),
            (['folder-create', '--title', '日本語 😀'], {'op': 'folder-create', 'title': '日本語 😀'}),
            (['folder-delete', 'synthetic-folder'], {'op': 'folder-delete', 'id': 'synthetic-folder'}),
            (['list'], {'op': 'list'}),
            (['list', '--folder', 'synthetic-folder'], {'op': 'list', 'folder': 'synthetic-folder'}),
            (['get', 'synthetic-template'], {'op': 'get', 'id': 'synthetic-template'}),
            (['delete', 'synthetic-template'], {'op': 'delete', 'id': 'synthetic-template'}),
            (['create', '--folder', 'f', '--title', 'T', '--content', '一\n二', '--enabled', 'false'],
             {'op': 'create', 'folder': 'f', 'title': 'T', 'content': '一\n二', 'enabled': False}),
            (['update', 's', '--title', 'New'], {'op': 'update', 'id': 's', 'title': 'New'}),
            (['update', 's', '--folder', 'f', '--content=', '--enabled=true'],
             {'op': 'update', 'id': 's', 'folder': 'f', 'content': '', 'enabled': True}),
            (['settings-schema'], {'op': 'settings-schema'}),
            (['settings-get'], {'op': 'settings-get'}),
            (['settings-get', '--key', 'appearance'], {'op': 'settings-get', 'key': 'appearance'}),
            (['settings-set', '--json', '{"appearance":"dark","auto_expiry_enabled":false}'],
             {'op': 'settings-set', 'values': {'appearance': 'dark', 'auto_expiry_enabled': False}}),
            (['app-action', 'permissions'], {'op': 'app-action', 'action': 'permissions'}),
            (['app-action', 'update-check'], {'op': 'app-action', 'action': 'update-check'}),
            (['bug-report', '--title', ' Bug ', '--description', ' Steps ', '--consent-source-info'],
             {'op': 'bug-report', 'title': 'Bug', 'description': 'Steps', 'contact': '', 'source_info_consent': True}),
        ]
        for arguments, expected in cases:
            with self.subTest(command=arguments[0], arguments=arguments):
                self.assert_request(arguments, expected)

    def test_app_override_before_after_and_equals_form(self):
        for arguments in (['--app', 'revclip-demo', 'settings-get'],
                          ['settings-get', '--app', 'revclip-demo'],
                          ['settings-get', '--app=revclip-demo']):
            with self.subTest(arguments=arguments):
                self.assert_request(arguments, {'op': 'settings-get'}, app='revclip-demo')
        self.assert_request(['--app=revclip-demo', 'settings-get', '--app', 'Revclip'], {'op': 'settings-get'})

    def test_help_is_json_and_does_not_connect(self):
        for arguments in (['--help'], ['settings-set', '--help']):
            completed, response, server = self.invoke(arguments)
            self.assertEqual(completed.returncode, 0)
            self.assertEqual(response['result']['default_app'], 'Revclip')
            self.assertIs(response['result']['history_readable'], False)
            self.assertIs(response['result']['clipboard_readable'], False)
            self.assertFalse(server.accepted)

    def test_content_file_stdin_and_image_are_explicit_bounded_inputs(self):
        text = '日本語\n😀\n'
        path = self.file(text.encode())
        for filename, stdin in ((path, b''), ('-', text.encode())):
            self.assert_request(['update', 's', '--content-file', filename],
                                {'op': 'update', 'id': 's', 'content': text}, input_bytes=stdin)
        # Synthetic PNG fixture; the fake app never parses or stores it.
        image = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jk1sAAAAASUVORK5CYII=')
        image_path = self.file(image)
        self.assert_request(['create', '--folder', 'f', '--title', 'Image', '--image', image_path],
                            {'op': 'create', 'folder': 'f', 'title': 'Image', 'image_base64': base64.b64encode(image).decode()})

    def test_settings_file_stdin_preserve_json_types_and_escaped_keys(self):
        text = r'{"appearance":"dark","auto_expiry_enabled":false,"max_history_size":30,"menu_custom_colors_dark":{"\u0074ext":"#ABCDEF"}}'
        expected = {'op': 'settings-set', 'values': json.loads(text)}
        path = self.file(text.encode())
        self.assert_request(['settings-set', '--file', path], expected)
        self.assert_request(['settings-set', '--file', '-'], expected, input_bytes=text.encode())

    def test_settings_reject_duplicate_keys_escaped_aliases_and_nonfinite(self):
        invalid = ['{}', '[]', 'null', '{"x":1,"x":2}', r'{"x":1,"\u0078":2}',
                   r'{"a":{"text":1,"\u0074ext":2}}', '{"a":[{"x":1,"x":2}]}',
                   '{"x":NaN}', '{"x":Infinity}', '{"x":-Infinity}', '{"x":1e9999}',
                   '{"x":1} trailing', '{"x":1,}', '{"x":"unterminated}']
        for text in invalid:
            with self.subTest(text=text):
                self.assert_rejected(['settings-set', '--json', text])

    def test_settings_nesting_limit_accepts_bounded_json_and_rejects_deep(self):
        bounded = '{"x":' + '[' * 8 + '0' + ']' * 8 + '}'
        self.assert_request(['settings-set', '--json', bounded], {'op': 'settings-set', 'values': json.loads(bounded)})
        deep = '{"x":' + '[' * 65 + '0' + ']' * 65 + '}'
        self.assert_rejected(['settings-set', '--json', deep])

    def test_invalid_utf8_files_and_stdin_fail_before_connecting(self):
        path = self.file(b'\xff\xfe\x80')
        for arguments in (['settings-set', '--file', path], ['update', 's', '--content-file', path],
                          ['bug-report', '--title', 'Bug', '--description-file', path, '--consent-source-info']):
            self.assert_rejected(arguments)
        self.assert_rejected(['settings-set', '--file', '-'], input_bytes=b'{"x":"\xff"}')
        self.assert_rejected(['update', 's', '--content-file', '-'], input_bytes=b'\xff')

    def test_regular_file_limits_and_stdin_limits(self):
        for limit, arguments in ((1024 * 1024, ['settings-set', '--file']),
                                 (1024 * 1024, ['update', 's', '--content-file']),
                                 (10 * 1024 * 1024, ['update', 's', '--image'])):
            # Sparse synthetic files avoid allocating large buffers in the test.
            path = self.file(b'')
            with path.open('r+b') as stream:
                stream.truncate(limit + 1)
            self.assert_rejected([*arguments, path])
        self.assert_rejected(['settings-set', '--file', '-'], input_bytes=b' ' * (1024 * 1024 + 1))
        self.assert_rejected(['update', 's', '--content-file', '-'], input_bytes=b'x' * (1024 * 1024 + 1))
        prefix = ['bug-report', '--title', 'Bug', '--consent-source-info', '--description-file']
        self.assert_rejected([*prefix, self.file(b'x' * 16385)])
        self.assert_rejected([*prefix, '-'], input_bytes=b'x' * 16385)
        exact = b'a' * (1024 * 1024)
        self.assert_request(['update', 's', '--content-file', '-'], {'op': 'update', 'id': 's', 'content': exact.decode()}, input_bytes=exact)

    def test_directory_and_fifo_are_rejected_without_blocking(self):
        self.assert_rejected(['settings-set', '--file', self.home])
        fifo = self.home / ('fifo-' + uuid.uuid4().hex)
        os.mkfifo(fifo, 0o600)
        self.assert_rejected(['update', 's', '--content-file', fifo])

    def test_report_consent_is_required_and_never_defaults_on(self):
        base = ['bug-report', '--title', 'Bug', '--description', 'Synthetic steps']
        self.assert_rejected(base, code=2)
        self.assert_rejected([*base, '--consent-source-info=false'], code=2)
        self.assert_rejected([*base, '--consent-source-info', '--history', 'yes'], code=2)
        self.assert_request([*base, '--contact', ' test@example.invalid ', '--consent-source-info'],
                            {'op': 'bug-report', 'title': 'Bug', 'description': 'Synthetic steps',
                             'contact': 'test@example.invalid', 'source_info_consent': True})
        text = ' 手順 😀 '
        self.assert_request(['bug-report', '--title', 'Bug', '--description-file', '-', '--consent-source-info'],
                            {'op': 'bug-report', 'title': 'Bug', 'description': text.strip(), 'contact': '', 'source_info_consent': True},
                            input_bytes=text.encode())

    def test_report_utf16_bounds(self):
        for title, description, contact in ((' ', 'steps', ''), ('x' * 121, 'steps', ''),
                                             ('Bug', '😀' * 1251, ''), ('Bug', 'steps', 'x' * 201)):
            self.assert_rejected(['bug-report', '--title', title, '--description', description,
                                  '--contact', contact, '--consent-source-info'])
        title, description, contact = '😀' * 60, '😀' * 1250, 'x' * 200
        self.assert_request(['bug-report', '--title', title, '--description', description,
                             '--contact', contact, '--consent-source-info'],
                            {'op': 'bug-report', 'title': title, 'description': description,
                             'contact': contact, 'source_info_consent': True})

    def test_usage_errors_are_exit_two_and_do_not_connect(self):
        for arguments in ([], ['get'], ['settings-set'], ['settings-set', '--json', '{"x":1}', '--file', '-'],
                          ['create', '--folder', 'f', '--title', 'T'], ['folder-create'],
                          ['update', 's', '--content', 'a', '--image', 'unused'],
                          ['update', 's', '--enabled', 'maybe'], ['--app', '../escape', 'folders'],
                          ['get', 's', '--history', 'yes'], ['list', '--id', 'history']):
            with self.subTest(arguments=arguments):
                self.assert_rejected(arguments, code=2)

    def test_history_and_clipboard_commands_are_rejected_without_connecting(self):
        for operation in ('history', 'history-get', 'clipboard', 'read-clipboard', 'export-history'):
            self.assert_rejected([operation], code=2)

    def test_backend_errors_are_preserved_for_ids_settings_and_actions(self):
        failure = {'ok': False, 'error': 'Synthetic backend rejection; no history exists here'}
        for arguments, expected in ((['get', 'history'], {'op': 'get', 'id': 'history'}),
                                    (['settings-get', '--key', 'raw_history'], {'op': 'settings-get', 'key': 'raw_history'}),
                                    (['app-action', 'restart'], {'op': 'app-action', 'action': 'restart'})):
            completed, response, server = self.invoke(arguments, response=failure)
            self.assertEqual(completed.returncode, 1)
            self.assertEqual(response, failure)
            self.assertEqual(server.request, expected)

    def test_fragmented_response_preserves_unicode_and_strict_envelope(self):
        expected = {'ok': True, 'result': {'title': '日本語 😀', 'values': [True, False, 123]}}
        response = self.assert_request(['folders'], {'op': 'folders'}, response=expected)
        self.assertEqual(response, expected)

    def test_malformed_response_envelopes_and_utf8_fail_closed(self):
        invalid = [b'not-json', b'\xff', encoded([]), encoded({}), encoded({'ok': 1, 'result': {}}),
                   encoded({'ok': 'true', 'result': {}}), encoded({'ok': True}),
                   encoded({'ok': False, 'error': 42})]
        for body in invalid:
            with self.subTest(body=body):
                completed, response, server = self.invoke(['folders'], wire=struct.pack('!I', len(body)) + body)
                self.assertEqual(completed.returncode, 1)
                self.assertIs(response['ok'], False)
                self.assertEqual(server.request, {'op': 'folders'})

    def test_response_caps_and_incomplete_frames_fail_closed(self):
        wires = [struct.pack('!I', RESPONSE_CAP + 1), struct.pack('!I', 0), struct.pack('!I', 0xffffffff),
                 b'\x00\x01', struct.pack('!I', 100) + b'{']
        for wire in wires:
            with self.subTest(wire=wire):
                completed, response, server = self.invoke(['folders'], wire=wire)
                self.assertEqual(completed.returncode, 1)
                self.assertIs(response['ok'], False)
                self.assertEqual(server.request, {'op': 'folders'})

    def test_socket_must_be_private_and_not_a_symlink(self):
        self.assert_rejected(['folders'], mode=0o666)
        endpoint = self.sockets['Revclip']
        target = self.home / 'fake-linked.sock'
        with FakeApp(target, {'ok': True, 'result': {}}) as server:
            endpoint.symlink_to(target)
            try:
                completed = self._process(['folders'])
                response = self._decode(completed)
            finally:
                endpoint.unlink()
        self.assertEqual(completed.returncode, 1)
        self.assertIs(response['ok'], False)
        self.assertFalse(server.accepted)


if __name__ == '__main__':
    unittest.main()
