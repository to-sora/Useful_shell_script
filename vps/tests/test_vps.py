#!/usr/bin/env python3
"""Isolated systemctl/apt mocks and real OpenSSH parser fixtures."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

VPS = Path(__file__).resolve().parents[1]


class VpsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vps-tests-')
        self.root = Path(self.temp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'calls.jsonl'
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}',
                        VPS_TEST_LOG=str(self.log))
        self.env.pop('SSH_CONNECTION', None)
        self.mock('systemctl', '''import json, os, sys
args = sys.argv[1:]
with open(os.environ['VPS_TEST_LOG'], 'a') as out: out.write(json.dumps(args) + '\\n')
if args[0] == os.environ.get('FAIL_ACTION'): sys.exit(7)
if args[0] == 'list-unit-files': print(os.environ.get('UNIT_LIST', ''))
elif args[0] == 'is-active': sys.exit(0 if args[-1] in os.environ.get('ACTIVE_UNITS', '').split() else 3)
''')
        self.mock('apt-get', '''import json, os, sys
args = sys.argv[1:]
with open(os.environ['VPS_TEST_LOG'], 'a') as out: out.write(json.dumps(args) + '\\n')
if os.environ.get('FAIL_ACTION') in args: sys.exit(9)
''')

    def tearDown(self):
        self.temp.cleanup()

    def mock(self, name, body):
        path = self.bin / name
        path.write_text('#!/usr/bin/env python3\n' + body)
        path.chmod(0o755)

    def run_script(self, script, *args, root=False, **env):
        command = ['bash', str(VPS / script), *map(str, args)]
        if root and os.geteuid() != 0:
            command = ['unshare', '-Ur', '--', *command]
        return subprocess.run(command, env=dict(self.env, **env), text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_shell_syntax_and_five_lines(self):
        for path in VPS.glob('*.sh'):
            self.assert_ok(subprocess.run(['bash', '-n', str(path)], text=True, capture_output=True))
        for name in ('enable-ssh.sh', 'disable-ssh.sh'):
            self.assertEqual(len((VPS / name).read_text().splitlines()), 5)

    def test_service_names_and_alias(self):
        for name in ('ssh', 'sshd'):
            with self.subTest(name=name):
                result = self.run_script('enable-ssh.sh', root=True, UNIT_LIST=f'{name}.service disabled enabled')
                self.assert_ok(result)
                self.assertEqual(self.calls()[-1], ['enable', '--now', f'{name}.service'])
        self.assert_ok(self.run_script('enable-ssh.sh', root=True,
                                      UNIT_LIST='ssh.service enabled enabled\nsshd.service alias -'))
        self.assertEqual(self.calls()[-1], ['enable', '--now', 'ssh.service'])

    def test_activation_modes(self):
        for active, expected in [('', 'ssh.socket'), ('ssh.socket', 'ssh.socket'),
                                 ('ssh.service', 'ssh.service'), ('ssh.service ssh.socket', 'ssh.socket')]:
            with self.subTest(active=active):
                result = self.run_script('enable-ssh.sh', root=True,
                                        UNIT_LIST='ssh.service disabled enabled\nssh.socket disabled enabled',
                                        ACTIVE_UNITS=active)
                self.assert_ok(result)
                self.assertEqual(self.calls()[-1], ['enable', '--now', expected])

    def test_stop_transaction_and_failures(self):
        units = 'ssh.service enabled enabled\nsshd.service alias -\nssh.socket enabled enabled'
        self.assert_ok(self.run_script('disable-ssh.sh', root=True, UNIT_LIST=units))
        self.assertEqual(self.calls()[-2:], [['disable', 'ssh.service', 'ssh.socket'],
                                            ['stop', 'ssh.service', 'ssh.socket']])
        for script, stage in [('enable-ssh.sh', 'list-unit-files'), ('enable-ssh.sh', 'enable'),
                              ('disable-ssh.sh', 'stop'), ('disable-ssh.sh', 'disable')]:
            with self.subTest(stage=stage):
                result = self.run_script(script, root=True, UNIT_LIST=units, FAIL_ACTION=stage)
                self.assertEqual(result.returncode, 7, result.stderr)
        for script in ('enable-ssh.sh', 'disable-ssh.sh'):
            self.assertNotEqual(self.run_script(script, root=True, UNIT_LIST='').returncode, 0)
        self.assertNotEqual(self.run_script('enable-ssh.sh', root=True,
                                           UNIT_LIST='ssh.service enabled enabled\nsshd.service enabled enabled').returncode, 0)

    def test_root_checks(self):
        if os.geteuid() == 0:
            self.skipTest('Non-root test requires an unprivileged test runner')
        for script in ('enable-ssh.sh', 'disable-ssh.sh', 'install-tools.sh'):
            self.assertNotEqual(self.run_script(script).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_apt_preview_and_install(self):
        result = self.run_script('install-tools.sh', '--list')
        self.assert_ok(result)
        packages = result.stdout.splitlines()
        self.assertEqual(len(packages), 35)
        self.assertEqual(len(set(packages)), len(packages))
        self.assertEqual(self.calls(), [])
        self.assert_ok(self.run_script('install-tools.sh', '--dry-run'))
        self.assertEqual(self.calls()[-1], ['--simulate', 'install', '--no-install-recommends', *packages])
        self.assert_ok(self.run_script('install-tools.sh', root=True))
        self.assertEqual(self.calls()[-2], ['-o', 'APT::Update::Error-Mode=any', 'update'])
        self.assertEqual(self.calls()[-1], ['install', '-y', '--no-install-recommends', *packages])
        for stage in ('update', 'install'):
            result = self.run_script('install-tools.sh', root=True, FAIL_ACTION=stage)
            self.assertEqual(result.returncode, 9)
            self.assertNotIn('installation completed', result.stdout)
        self.assertEqual(self.run_script('install-tools.sh', '--list', 'extra').returncode, 2)

    def make_config(self, body):
        key = self.root / 'hostkey'
        if not key.exists():
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
        config = self.root / 'sshd_config'
        config.write_text(f'HostKey {key}\n' + body)
        return config

    def audit(self, config, user='root', *extra):
        return self.run_script('check-ssh-config.sh', '--config', config, '--user', user,
                               '--addr', '198.51.100.20', '--laddr', '203.0.113.10', *extra)

    def setting(self, output, keyword):
        lines = output.splitlines()
        for index, line in enumerate(lines):
            if f'({keyword}): ' in line:
                return line.split(f'({keyword}): ', 1)[1], lines[index + 1].strip()
        self.fail(f'Setting absent: {keyword}')

    def test_duplicate_global_and_defaults(self):
        config = self.make_config('PasswordAuthentication no\nPasswordAuthentication yes\n')
        result = self.audit(config)
        self.assert_ok(result)
        self.assertEqual(self.setting(result.stdout, 'passwordauthentication'), ('no', f'來源：{config}:2'))
        self.assertEqual(self.setting(result.stdout, 'pubkeyauthentication')[1], '來源：OpenSSH 內建預設')
        self.assertIn('OS:', result.stdout)
        self.assertIn('user=root,addr=198.51.100.20', result.stdout)

    def test_include_match_and_cli_provenance(self):
        snippets = self.root / 'sshd_config.d'
        snippets.mkdir()
        first = snippets / '10-first.conf'
        nested = self.root / 'nested.conf'
        nested.write_text('PasswordAuthentication no\nMatch User root\nPasswordAuthentication yes\nPermitRootLogin yes\n')
        first.write_text(f'Include {nested}\n')
        (snippets / '90-last.conf').write_text('Match all\nPasswordAuthentication no\n')
        config = self.make_config(f'Include {snippets}/*.conf\nMatch User nobody\nPermitRootLogin no\nMatch User root\nAuthenticationMethods publickey,password\n')
        result = self.audit(config, 'root', '--option', 'PasswordAuthentication=no')
        self.assert_ok(result)
        self.assertEqual(self.setting(result.stdout, 'passwordauthentication'), ('yes', f'來源：{nested}:3'))
        self.assertEqual(self.setting(result.stdout, 'authenticationmethods'), ('publickey,password', f'來源：{config}:6'))
        self.assertIn('公鑰必要性（認證規則）：必要', result.stdout)
        self.assertIn('password 方法路徑：publickey,password', result.stdout)
        self.assertIn(f'{first}:1: Include', result.stdout)
        config = self.make_config('PasswordAuthentication yes\n')
        result = self.audit(config, 'root', '--option', 'PasswordAuthentication=no')
        self.assert_ok(result)
        self.assertEqual(self.setting(result.stdout, 'passwordauthentication'), ('no', '來源：命令列 --option PasswordAuthentication=no'))

    def test_lists_and_root_scope(self):
        config = self.make_config('AllowUsers ubuntu\nMatch User root\nAllowUsers root\nDenyUsers blocked\nMatch User root\nDenyUsers test\n')
        result = self.audit(config)
        self.assert_ok(result)
        self.assertEqual(self.setting(result.stdout, 'allowusers'), ('root', f'來源：{config}:4'))
        self.assertEqual(self.setting(result.stdout, 'denyusers'), ('blocked test', f'來源：{config}:5, {config}:7'))
        self.assertIn('AllowUsers 帳號範圍：root', result.stdout)
        self.assertIn(f'{config}:3: Match User root', result.stdout)

    def test_authentication_alternatives(self):
        cases = [
            ('PermitRootLogin yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\n', 'root', '必要'),
            ('PermitRootLogin yes\nPasswordAuthentication no\nKbdInteractiveAuthentication yes\nUsePAM yes\n', 'root', '存在免公鑰認證路徑'),
            ('PermitRootLogin yes\nPasswordAuthentication no\nKbdInteractiveAuthentication yes\nUsePAM no\n', 'root', '必要'),
            ('PermitRootLogin prohibit-password\nPasswordAuthentication yes\nKbdInteractiveAuthentication yes\n', 'root', '必要'),
            ('PermitRootLogin no\n', 'root', '登入受設定封鎖'),
            ('PermitRootLogin forced-commands-only\n', 'root', '必要；公鑰須綁定強制指令'),
            ('AuthenticationMethods publickey,password publickey,keyboard-interactive\n', 'nobody', '必要'),
            ('AuthenticationMethods publickey password\n', 'nobody', '存在免公鑰認證路徑'),
            ('AuthenticationMethods publickey password\nPasswordAuthentication no\n', 'nobody', '必要'),
        ]
        for body, user, expected in cases:
            with self.subTest(body=body):
                result = self.audit(self.make_config(body), user)
                self.assert_ok(result)
                self.assertIn(f'公鑰必要性（認證規則）：{expected}\n', result.stdout)

    def test_pam_device_and_summary(self):
        config = self.make_config('PasswordAuthentication no\nKbdInteractiveAuthentication yes\nUsePAM no\nAuthenticationMethods publickey keyboard-interactive:pam\n')
        result = self.audit(config, 'nobody')
        self.assert_ok(result)
        self.assertIn('公鑰必要性（認證規則）：必要\n', result.stdout)
        self.assertIn('keyboard-interactive 路徑：停用\n', result.stdout)
        config = self.make_config('PasswordAuthentication no\nKbdInteractiveAuthentication yes\nUsePAM yes\nAuthenticationMethods keyboard-interactive:pam\n')
        result = self.audit(config, 'nobody')
        self.assert_ok(result)
        self.assertIn('password 方法路徑：停用\n', result.stdout)
        self.assertIn('keyboard-interactive 路徑：keyboard-interactive:pam；PAM 服務 sshd', result.stdout)
        self.assertIn('密碼／OTP 步驟由 PAM 模組定義', result.stdout)

    def test_alias_and_parser_errors(self):
        config = self.make_config('ChallengeResponseAuthentication no\n')
        result = self.audit(config)
        self.assert_ok(result)
        self.assertEqual(self.setting(result.stdout, 'kbdinteractiveauthentication'), ('no', f'來源：{config}:2'))
        config = self.make_config('BogusSetting yes\n')
        result = self.audit(config)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('BogusSetting', result.stderr)
        self.assertNotEqual(self.run_script('check-ssh-config.sh', '--lport', '0').returncode, 0)
        self.assertNotEqual(self.run_script('check-ssh-config.sh', '--addr', 'invalid').returncode, 0)


if __name__ == '__main__':
    if not (shutil.which('sshd') or Path('/usr/sbin/sshd').exists()):
        raise SystemExit('OpenSSH server executable required for parser tests')
    unittest.main(verbosity=2)
