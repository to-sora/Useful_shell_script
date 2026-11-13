#!/usr/bin/env bash
set -euo pipefail
exec python3 - "$@" <<'PY'
import argparse
import collections
import ipaddress
import os
from pathlib import Path
import pwd
import re
import shlex
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description='Read-only OpenSSH configuration audit with file/line provenance.')
parser.add_argument('--config', default='/etc/ssh/sshd_config', help='sshd configuration file')
parser.add_argument('--user', action='append', help='target account; repeat for multiple accounts')
parser.add_argument('--addr', help='client IP; default: SSH_CONNECTION client or 127.0.0.1')
parser.add_argument('--host', help='resolved client hostname used for Match Host; default: client IP')
parser.add_argument('--laddr', help='server IP; default: SSH_CONNECTION server or 127.0.0.1')
parser.add_argument('--lport', type=int, help='server port; default: SSH_CONNECTION port or 22')
parser.add_argument('--option', action='append', default=[], metavar='KEY=VALUE', help='sshd -o override; repeat as needed')
args = parser.parse_args()
config = str(Path(args.config).resolve())
connection = os.environ.get('SSH_CONNECTION', '').split()
addr = args.addr or (connection[0] if len(connection) == 4 else '127.0.0.1')
laddr = args.laddr or (connection[2] if len(connection) == 4 else '127.0.0.1')
lport = args.lport if args.lport is not None else int(connection[3]) if len(connection) == 4 else 22
host = args.host or addr
for address in (addr, laddr):
    try:
        ipaddress.ip_address(address)
    except ValueError:
        parser.error('addr and laddr require IPv4 or IPv6 addresses')
if not 1 <= lport <= 65535:
    parser.error('lport must be 1..65535')
users = args.user or list(dict.fromkeys(['root', os.environ.get('SUDO_USER') or pwd.getpwuid(os.getuid()).pw_name]))
if any(not value or any(c in value for c in ',\r\n=') for value in [host, *users]):
    parser.error('user and host must be nonempty and exclude comma, equals, CR, and LF')
sshd = shutil.which('sshd') or next((p for p in ('/usr/sbin/sshd', '/usr/local/sbin/sshd') if os.access(p, os.X_OK)), None)
if sshd is None:
    parser.error('OpenSSH server executable required')

def os_details():
    for filename in ('/etc/os-release', '/usr/lib/os-release'):
        path = Path(filename)
        if path.is_file():
            data = {}
            for line in path.read_text().splitlines():
                if '=' in line and not line.startswith('#'):
                    key, value = line.split('=', 1)
                    tokens = shlex.split(value)
                    data[key] = ' '.join(tokens)
            return data.get('PRETTY_NAME', data.get('NAME', 'Linux')), filename
    return ' '.join(os.uname()[:3]), 'uname'

labels = {
    'passwordauthentication': '密碼認證',
    'kbdinteractiveauthentication': '互動式認證',
    'pubkeyauthentication': '公鑰認證',
    'authenticationmethods': '認證方法組合',
    'permitrootlogin': 'root 登入策略',
    'allowusers': '允許使用者模式',
    'denyusers': '拒絕使用者模式',
    'allowgroups': '允許群組模式',
    'denygroups': '拒絕群組模式',
    'usepam': 'PAM',
    'pamservicename': 'PAM 服務名稱',
    'gssapiauthentication': 'GSSAPI 認證',
    'hostbasedauthentication': '主機認證',
    'permitemptypasswords': '空密碼',
    'authorizedkeysfile': '公鑰檔案',
    'authorizedkeyscommand': '公鑰查詢指令',
    'forcecommand': '強制指令',
    'refuseconnection': '拒絕連線',
}
lists = {'allowusers', 'denyusers', 'allowgroups', 'denygroups'}
aliases = {'challengeresponseauthentication': 'kbdinteractiveauthentication'}
event_re = re.compile(r'^debug3: (.+):(\d+) setting (\S+)\s*(.*)$')
option_re = re.compile(r'^\s*([^\s=]+)[\s=]+(.*)$')
overrides = collections.defaultdict(list)
for option in args.option:
    match = option_re.match(option)
    if not match:
        parser.error('--option requires KEY=VALUE or KEY VALUE')
    key = aliases.get(match[1].lower(), match[1].lower())
    overrides[key].append(option)

def inspect(user):
    context = f'user={user},addr={addr},host={host},laddr={laddr},lport={lport}'
    command = [sshd, '-T', '-ddd', '-f', config, '-C', context]
    for option in args.option:
        command.extend(['-o', option])
    result = subprocess.run(command, text=True, capture_output=True, env=dict(os.environ, LC_ALL='C'))
    if result.returncode:
        print(f'OpenSSH 設定檢測失敗：{config}', file=sys.stderr)
        print(result.stderr.strip(), file=sys.stderr)
        raise SystemExit(result.returncode)
    effective = {}
    for line in result.stdout.splitlines():
        key, _, value = line.partition(' ')
        effective[key] = f'{effective[key]} {value}' if key in lists and key in effective else value
    phases = [collections.defaultdict(list), collections.defaultdict(list)]
    phase = 0
    paths = {config}
    for line in result.stderr.splitlines():
        if 'config reprocess config ' in line:
            phase = 1
        match = event_re.match(line)
        if match:
            filename, number, key, value = match.groups()
            filename = config if filename == 'reprocess config' else filename
            key = aliases.get(key.lower(), key.lower())
            phases[phase][key].append((filename, int(number), value))
            if filename != 'command-line':
                paths.add(filename)
        loaded = re.search(r'load_server_config: filename (.+)$', line)
        if loaded:
            paths.add(loaded[1])
    sources = {}
    for key in labels:
        # Match-pass values override globals; scalar directives keep the first value.
        selected = phases[1].get(key) or phases[0].get(key, [])
        sources[key] = selected if key in lists else selected[:1]
    return context, effective, sources, paths, set(phases[1])

def auth_summary(user, values):
    enabled = {
        'publickey': values.get('pubkeyauthentication', 'no') != 'no',
        'password': values.get('passwordauthentication') == 'yes',
        'keyboard-interactive': values.get('kbdinteractiveauthentication') == 'yes',
        'gssapi-with-mic': values.get('gssapiauthentication') == 'yes',
        'hostbased': values.get('hostbasedauthentication') == 'yes',
        'none': values.get('permitemptypasswords') == 'yes' and values.get('passwordauthentication') == 'yes',
    }
    root_policy = values.get('permitrootlogin')
    # Linux OpenSSH uses PAM as its keyboard-interactive backend.
    if sys.platform.startswith('linux') and values.get('usepam') != 'yes':
        enabled['keyboard-interactive'] = False
    if values.get('refuseconnection') == 'yes' or (user == 'root' and root_policy == 'no'):
        return ('登入受設定封鎖',) * 3
    if user == 'root' and root_policy in ('without-password', 'prohibit-password'):
        for method in ('password', 'keyboard-interactive', 'none'):
            enabled[method] = False
    if user == 'root' and root_policy == 'forced-commands-only':
        enabled = {method: method == 'publickey' and value for method, value in enabled.items()}
    methods = values.get('authenticationmethods', 'any')
    alternatives = [[method] for method, value in enabled.items() if value] if methods == 'any' else [part.split(',') for part in methods.split()]
    def available(method):
        name, _, device = method.partition(':')
        if name == 'keyboard-interactive' and device:
            if device == 'pam' and values.get('usepam') != 'yes':
                return False
            if sys.platform.startswith('linux') and device != 'pam':
                return False
        return enabled.get(name, False)
    viable = [path for path in alternatives if all(available(method) for method in path)]
    if not viable:
        return ('認證方法組合受設定封鎖',) * 3
    key_required = all(any(method.split(':', 1)[0] == 'publickey' for method in path) for path in viable)
    key_text = '必要' if key_required else '存在免公鑰認證路徑'
    if user == 'root' and root_policy == 'forced-commands-only':
        key_text += '；公鑰須綁定強制指令'
    password_paths = [','.join(path) for path in viable if 'password' in path]
    interactive_paths = [','.join(path) for path in viable if any(method.split(':', 1)[0] == 'keyboard-interactive' for method in path)]
    interactive = ' / '.join(interactive_paths) if interactive_paths else '停用'
    if interactive_paths and values.get('usepam') == 'yes':
        interactive += f"；PAM 服務 {values.get('pamservicename', 'sshd')}，密碼／OTP 步驟由 PAM 模組定義"
    return key_text, ' / '.join(password_paths) if password_paths else '停用', interactive

name, os_source = os_details()
version = subprocess.run([sshd, '-V'], text=True, capture_output=True)
print(f'OS: {name} [{os_source}]')
print(f'OpenSSH: {(version.stderr or version.stdout).strip()}')
print(f'設定檔：{config}\n檢測範圍：磁碟設定與指定連線條件')
all_paths = set()
for user in users:
    context, values, sources, paths, matched_keys = inspect(user)
    all_paths.update(paths)
    print(f'\n連線條件：{context}')
    for key, label in labels.items():
        value = values.get(key, '(空集合)' if key in lists else '(此版本未輸出)')
        if key in overrides and key not in lists and key not in matched_keys:
            origin = f'命令列 --option {overrides[key][0]}'
        else:
            locations = [f'{path}:{number}' for path, number, _ in sources[key]]
            if key in lists and key in overrides and key not in matched_keys:
                locations = [f'命令列 --option {item}' for item in overrides[key]] + locations
            origin = ', '.join(locations) if locations else 'OpenSSH 內建預設'
        print(f'{label} ({key}): {value}\n  來源：{origin}')
    key_text, password_text, interactive_text = auth_summary(user, values)
    print(f'公鑰必要性（認證規則）：{key_text}\npassword 方法路徑：{password_text}\nkeyboard-interactive 路徑：{interactive_text}')
    allowed = values.get('allowusers', '').split()
    root_only = bool(allowed) and all(token.split('@', 1)[0] == 'root' for token in allowed)
    print('AllowUsers 帳號範圍：' + ('root' if root_only else values.get('allowusers', '全體帳號')))
    print('帳號准入規則：DenyUsers → AllowUsers → DenyGroups → AllowGroups；PAM 與帳號狀態另作限制。')

print('\n設定宣告清單（含條件區段；生效值見上表）：')
for filename in sorted(all_paths):
    path = Path(filename)
    if not path.is_file():
        continue
    for number, line in enumerate(path.read_text(errors='replace').splitlines(), 1):
        match = option_re.match(line)
        if match and (aliases.get(match[1].lower(), match[1].lower()) in labels or match[1].lower() in ('include', 'match')):
            print(f'{filename}:{number}: {line.strip()}')
PY
