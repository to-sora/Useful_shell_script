#!/usr/bin/env bash
# Standalone Linux CPython patch updater. See update_python_envs.md.
# Bash starts the embedded standard-library engine; no companion .py is needed.
set -euo pipefail

updater_python="${PY_ENV_UPDATER_PYTHON:-}"
if [[ -n "$updater_python" ]]; then
  command -v -- "$updater_python" >/dev/null 2>&1 || {
    printf 'ERROR: PY_ENV_UPDATER_PYTHON executable was not found.\n' >&2
    exit 2
  }
else
  for candidate in python3 python3.13 python3.12 python3.11 python3.10 python3.9 python3.8; do
    if command -v "$candidate" >/dev/null 2>&1 &&
      "$candidate" -I -c 'import sys; raise SystemExit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
      updater_python="$(command -v "$candidate")"
      break
    fi
  done
fi
if [[ -z "$updater_python" ]] ||
  ! "$updater_python" -I -c 'import sys; raise SystemExit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
  printf 'ERROR: A control Python >= 3.8 is required; set PY_ENV_UPDATER_PYTHON.\n' >&2
  exit 2
fi

run_engine() {
  "$updater_python" -I - "$@" <<'PY_ENV_UPDATE_ENGINE'
"""Discover and patch private CPython installations and virtual environments.

Python >= 3.8, Linux. Explicit roots and target binaries are required.
Scan follows directory links, deduplicates inode cycles, and probes actual binaries.
Patch releases within one minor branch preserve third-party packages. Each update
uses a staged copy, validation, an adjacent backup, and a durable journal.
"""
import argparse
import datetime
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys
import time
import uuid
import fcntl

PYNAME = re.compile(r"python(?:[0-9]+(?:\.[0-9]+)*)?$")
MARKER = ".pyenv-update-"
EOL = {"3.8": "2024-10-07", "3.10": "2026-10-01"}
PATCH_FLOORS = {"3.8": "3.8.20", "3.10": "3.10.22", "3.11": "3.11.18", "3.13": "3.13.18"}
PROBE = r'''
import json,sys,sysconfig,platform,os
print(json.dumps(dict(version=platform.python_version(), executable=sys.executable,
 prefix=sys.prefix,base_prefix=getattr(sys,'real_prefix',sys.base_prefix),
 implementation=platform.python_implementation(),soabi=sysconfig.get_config_var('SOABI'),
 shared=sysconfig.get_config_var('Py_ENABLE_SHARED'),machine=platform.machine(),
 pointer_bits=__import__('struct').calcsize('P')*8)))
'''
PACKAGES = r'''
import importlib.metadata as m,json,re,os,sys
out={}; direct=[]; scripts=[]; ignored_metadata=[]
for d in m.distributions():
 name=d.metadata.get('Name')
 if not name or not d.version:
  metadata_path=getattr(d,'_path',None)
  # pip can leave empty dist-info directory trees after an uninstall. They
  # contain no installed distribution; populated corrupt metadata is an error.
  if metadata_path and os.path.isdir(metadata_path) and not any(files for _,_,files in os.walk(metadata_path)):
   ignored_metadata.append(str(metadata_path)); continue
  raise RuntimeError('Incomplete distribution metadata: '+str(metadata_path))
 name=re.sub('[-_.]+','-',name).lower()
 out[name]=d.version
 if d.read_text('direct_url.json'): direct.append(name)
 for ep in d.entry_points:
  if ep.group=='console_scripts': scripts.append(ep.name)
present=[n for n in sorted(set(scripts)) if os.path.isfile(os.path.join(sys.prefix,'bin',n))]
print(json.dumps(dict(packages=out,direct_url=direct,console_scripts=sorted(set(scripts)),present_console_scripts=present,ignored_empty_metadata=ignored_metadata)))
'''
CORE_CHECK = r'''
import ssl,sqlite3,bz2,lzma,ctypes,venv,json,sys,hashlib,zlib,time
assert len(time.strftime('%Y'))==4
assert sqlite3.connect(':memory:').execute('select 6*7').fetchone()[0]==42
data=b'python-environment-updater'*30
assert bz2.decompress(bz2.compress(data))==data
assert lzma.decompress(lzma.compress(data))==data
print(json.dumps(dict(version=sys.version,openssl=ssl.OPENSSL_VERSION,sqlite=sqlite3.sqlite_version)))
'''

class UpdateError(Exception): pass

def utcnow():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()

def emit(event, **fields):
    print(json.dumps(dict(event=event, **fields)), flush=True)

def version_tuple(v):
    if not re.fullmatch(r"\d+\.\d+\.\d+", v):
        raise UpdateError("A stable three-component CPython version is required: " + v)
    return tuple(map(int, v.split('.')))

def branch(v): return '.'.join(v.split('.')[:2])

def canon(p): return str(Path(p).resolve())

def within(p, root):
    try: Path(p).resolve().relative_to(Path(root).resolve()); return True
    except ValueError: return False

def atomic_json(path, data):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + '.tmp-' + uuid.uuid4().hex)
    with tmp.open('w') as f:
        json.dump(data, f, indent=2, sort_keys=True); f.write('\n'); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, path)
    fd=os.open(str(path.parent), os.O_DIRECTORY)
    try: os.fsync(fd)
    finally: os.close(fd)

def run(argv, timeout=120, cwd=None):
    env=os.environ.copy()
    for key in list(env):
        if key.startswith('PYTHON') or key in ('VIRTUAL_ENV','CONDA_PREFIX'):
            env.pop(key,None)
    env['PIP_DISABLE_PIP_VERSION_CHECK']='1'
    env['PIP_NO_INPUT']='1'
    try:
        result=subprocess.run([str(a) for a in argv],cwd=cwd,env=env,timeout=timeout,
                              text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    except (OSError,subprocess.TimeoutExpired) as e:
        raise UpdateError(str(e))
    if result.returncode:
        raise UpdateError('Command failed (exit '+str(result.returncode)+'): '+repr([str(a) for a in argv])+'\n'+result.stdout[-4000:]+result.stderr[-4000:])
    return result.stdout

def run_json(binary, code):
    output=run([binary,'-I','-c',code],timeout=45)
    try: return json.loads(output)
    except ValueError: raise UpdateError('Interpreter returned invalid JSON: '+str(binary))

def executable_file(path):
    try:
        if not path.is_file() or not os.access(str(path),os.X_OK): return False
        with path.open('rb') as f: return f.read(4)==b'\x7fELF'
    except OSError: return False

def probe(binary):
    # Preserve the invocation path: resolving a venv interpreter link here would
    # execute its base interpreter outside the environment.
    binary=Path(os.path.abspath(str(binary)))
    if not executable_file(binary): raise UpdateError('Missing or non-ELF Python binary: '+str(binary))
    info=run_json(binary,PROBE)
    if info['implementation']!='CPython': raise UpdateError('CPython is required')
    info['prefix']=canon(info['prefix']); info['base_prefix']=canon(info['base_prefix'])
    info['binary']=str(binary)
    version_tuple(info['version'])
    return info

def binary_names(prefix):
    bindir=Path(prefix)/'bin'
    if not bindir.is_dir(): return []
    return sorted((p.name for p in bindir.iterdir() if PYNAME.fullmatch(p.name)),
                  key=lambda n:(n!='python',n!='python3',n))

def unresolved_aliases(prefix, version):
    standard={'python','python3','python'+branch(version)}
    return [name for name in binary_names(prefix)
            if name not in standard and not executable_file(Path(prefix)/'bin'/name)]

def manager(prefix):
    p=Path(prefix)
    if (p/'conda-meta').is_dir():return 'conda'
    index=p/'info/index.json'
    if index.is_file():
        try:
            if json.loads(index.read_text()).get('name')=='python':return 'conda-package-cache'
        except (ValueError,OSError):pass
    return 'private'

def scan(roots, exclude=()):
    records={}; warnings=[]; links=[]; visited=set(); candidates=[]; cfg_paths=[]
    excluded=[canon(p) for p in exclude]
    stack=[Path(os.path.abspath(str(p))) for p in roots]
    while stack:
        path=stack.pop()
        if MARKER in path.name or any(within(path,p) for p in excluded): continue
        try:
            if path.is_symlink():
                links.append(dict(path=str(path),target=canon(path),exists=path.exists()))
            if not path.exists():
                warnings.append(dict(path=str(path),reason='broken_link_or_missing_root')); continue
            if path.is_file():
                if PYNAME.fullmatch(path.name): candidates.append(path)
                continue
            if (path/'pyvenv.cfg').is_file(): cfg_paths.append(path)
            st=path.stat(); key=(st.st_dev,st.st_ino)
            if key in visited: continue
            visited.add(key)
            with os.scandir(path) as entries:
                for ent in entries:
                    p=Path(ent.path)
                    if MARKER in ent.name: continue
                    if ent.is_dir(follow_symlinks=True): stack.append(p)
                    elif ent.name=='pyvenv.cfg': pass
                    elif path.name=='bin' and PYNAME.fullmatch(ent.name): candidates.append(p)
                    elif ent.is_symlink() and not p.exists():
                        warnings.append(dict(path=str(p),reason='broken_link'))
        except (OSError,RuntimeError) as e:
            warnings.append(dict(path=str(path),reason=str(e)))
    # Config markers are useful candidates, but the executable determines identity.
    for p in cfg_paths:
        names=binary_names(p)
        if not names: warnings.append(dict(path=str(p),reason='pyvenv.cfg_without_python_binary'))
        candidates.extend(p/'bin'/name for name in names)
    probed=set()
    for p in candidates:
        invocation=str(p)
        if invocation in probed: continue
        probed.add(invocation)
        try:
            info=probe(p); key=info['prefix']
            kind='venv' if info['prefix']!=info['base_prefix'] else 'raw'
            rec=records.setdefault(key,dict(prefix=key,kind=kind,version=info['version'],
                base_prefix=info['base_prefix'],binary=str(Path(key)/'bin'/p.name),
                aliases=[],binaries=[],versions=[],soabi=info['soabi'],shared=info['shared'],
                machine=info['machine'],pointer_bits=info['pointer_bits'],
                managed=manager(key)))
            rec['aliases'].append(invocation)
            rec['binaries'].append(dict(path=invocation,version=info['version'],
                                       resolved=canon(p),prefix=info['prefix']))
            if info['version'] not in rec['versions']:rec['versions'].append(info['version'])
        except UpdateError as e: warnings.append(dict(path=invocation,reason=str(e)))
    # A venv can reference a raw installation beyond the traversal roots.
    for rec in list(records.values()):
        base=rec['base_prefix']
        if rec['kind']=='venv' and base not in records:
            names=binary_names(base)
            for name in names:
                try:
                    info=probe(Path(base)/'bin'/name)
                    if branch(info['version'])!=branch(rec['version']): continue
                    records[base]=dict(prefix=base,kind='raw',version=info['version'],
                        base_prefix=base,binary=info['binary'],aliases=[info['binary']],
                        binaries=[dict(path=info['binary'],version=info['version'],resolved=canon(info['binary']),prefix=base)],
                        versions=[info['version']],soabi=info['soabi'],shared=info['shared'],
                        machine=info['machine'],pointer_bits=info['pointer_bits'],
                        managed=manager(base),
                        referenced_only=True)
                    break
                except UpdateError: continue
    for rec in records.values():
        rec['unresolved_aliases']=unresolved_aliases(rec['prefix'],rec['version'])
        rec['binary_errors']=[w for w in warnings if canon(Path(w['path']).parent)==str(Path(rec['prefix'])/'bin')]
    return dict(created=utcnow(),roots=[os.path.abspath(str(p)) for p in roots],
                environments=sorted(records.values(),key=lambda r:r['prefix']),
                warnings=warnings,symlinks=links,visited_directories=len(visited))

def packages(binary): return run_json(binary,PACKAGES)

def runtime_hashes(prefix, kind):
    prefix=Path(prefix)
    files=[prefix/'bin'/name for name in binary_names(prefix)]
    if kind=='raw':
        files+=list((prefix/'lib').glob('python*/lib-dynload/*.so'))
        for pattern in ('python*/tarfile.py','python*/ssl.py','python*/urllib/request.py'):
            files+=list((prefix/'lib').glob(pattern))
    return {str(p.relative_to(prefix)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()}

def interpreter_images(prefix):
    images={}
    for name in binary_names(prefix):
        p=Path(prefix)/'bin'/name
        images[name]=dict(link=os.readlink(p)) if p.is_symlink() else dict(
            data=p.read_bytes(),mode=stat.S_IMODE(p.stat().st_mode))
    return images

def publish_interpreters(prefix, images):
    # Publish binary entries at their final paths and flush the binary directory.
    bindir=Path(prefix)/'bin'
    for name,spec in images.items():
        tmp=bindir/(MARKER+uuid.uuid4().hex+'.interpreter')
        try:
            if 'link' in spec:tmp.symlink_to(spec['link'])
            else:
                with tmp.open('xb') as f:
                    f.write(spec['data']);f.flush();os.fsync(f.fileno())
                tmp.chmod(spec['mode'])
            os.utime(tmp,None,follow_symlinks=False)
            destination=bindir/name
            # Remove the old entry before publishing and flushing its replacement.
            if destination.exists() or destination.is_symlink():destination.unlink()
            if 'link' in spec:
                destination.symlink_to(spec['link'])
                os.utime(destination,None,follow_symlinks=False)
            else:
                with destination.open('xb') as f:
                    f.write(spec['data']);f.flush();os.fsync(f.fileno())
                destination.chmod(spec['mode']);os.utime(destination,None)
        finally:
            if tmp.exists() or tmp.is_symlink():tmp.unlink()
    fd=os.open(str(bindir),os.O_DIRECTORY)
    try:os.fsync(fd)
    finally:os.close(fd)

def copy_into_existing(source, destination):
    """Mirror a validated tree while retaining the live prefix directory inode.

    Keep the prefix directory in place. Applications must be stopped because
    publication spans multiple file operations.
    """
    source=Path(source);destination=Path(destination)
    def remove(path):
        if path.is_symlink() or not path.is_dir():path.unlink()
        else:shutil.rmtree(path)
    if source.is_symlink():
        if destination.exists() or destination.is_symlink():remove(destination)
        destination.symlink_to(os.readlink(source))
        os.utime(destination,None,follow_symlinks=False)
    elif source.is_dir():
        if destination.is_symlink() or (destination.exists() and not destination.is_dir()):remove(destination)
        destination.mkdir(exist_ok=True)
        names={p.name for p in source.iterdir()}
        for p in source.iterdir():copy_into_existing(p,destination/p.name)
        for p in destination.iterdir():
            if p.name not in names:remove(p)
        shutil.copystat(source,destination,follow_symlinks=False)
        os.utime(destination,None)
    else:
        tmp=destination.with_name(MARKER+uuid.uuid4().hex+'.file')
        try:
            shutil.copy2(source,tmp);os.utime(tmp,None)
            if destination.is_symlink() or destination.is_dir():remove(destination)
            os.replace(tmp,destination)
        finally:
            if tmp.exists():tmp.unlink()

def validate(prefix, expected_version, expected_packages=None, checks=None, final=False, expected_scripts=None, expected_hashes=None):
    prefix=Path(prefix); infos=[]
    unresolved=unresolved_aliases(prefix,expected_version)
    names=[name for name in binary_names(prefix) if name not in unresolved]
    if not names: raise UpdateError('No Python executables in '+str(prefix))
    for relative,expected in (expected_hashes or {}).items():
        path=prefix/relative
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
            raise UpdateError('Runtime file integrity mismatch: '+str(path))
    for name in names:
        info=probe(prefix/'bin'/name)
        if info['version']!=expected_version:
            raise UpdateError('Interpreter alias has unexpected version: '+str(prefix/'bin'/name))
        if info['prefix']!=canon(prefix):
            raise UpdateError('Interpreter escaped environment: '+str(prefix/'bin'/name))
        infos.append(info)
    binary=str(prefix/'bin'/names[0])
    core=run_json(binary,CORE_CHECK)
    installed=packages(binary)
    if expected_packages is not None and installed['packages']!=expected_packages:
        raise UpdateError('Installed package inventory changed')
    pip_check='pip absent'
    if 'pip' in installed['packages']:
        pip_check=run([binary,'-I','-m','pip','check']).strip()
    results=[]
    for check in checks or []:
        if check.get('final_only') and not final:continue
        argv=[s.replace('{python}',binary).replace('{prefix}',str(prefix)) for s in check['argv']]
        output=run(argv,timeout=check.get('timeout',60),cwd=str(prefix))
        if check.get('contains') and check['contains'] not in output:
            raise UpdateError('Smoke check output mismatch: '+repr(argv))
        results.append(dict(argv=argv,output=output[-2000:]))
    # Entry points must survive publication at their existing paths.
    if final:
        missing=[n for n in (expected_scripts or []) if not (prefix/'bin'/n).is_file()]
        if missing:raise UpdateError('Missing console scripts: '+repr(missing))
    return dict(interpreters=infos,core=core,packages=installed,pip_check=pip_check,checks=results,
                unresolved_aliases=[dict(path=str(prefix/'bin'/name),reason='Nonstandard alias has no usable ELF interpreter; intended version is unknown') for name in unresolved])

def read_cfg(prefix):
    result={}; p=Path(prefix)/'pyvenv.cfg'
    if p.is_file():
        for line in p.read_text().splitlines():
            if '=' in line:
                k,v=line.split('=',1); result[k.strip()]=v.strip()
    return result

def patch_venv(stage, target, original):
    cfg=read_cfg(stage)
    if not cfg: raise UpdateError('Legacy environment lacks pyvenv.cfg; migration requires a package rebuild')
    unresolved=unresolved_aliases(stage,probe(target)['version'])
    names=[name for name in binary_names(stage) if name not in unresolved]
    for name in names:
        p=stage/'bin'/name
        if p.is_dir():raise UpdateError('Unexpected interpreter directory')
        p.unlink()
    args=[target,'-I','-m','venv','--upgrade','--without-pip','--copies',
          '--prompt',cfg.get('prompt',Path(original).name).strip("'\"")]
    if cfg.get('include-system-site-packages','false').lower()=='true': args.append('--system-site-packages')
    run(args+[str(stage)],timeout=120)
    for name in names:
        p=stage/'bin'/name
        if not p.exists():
            shutil.copyfile(stage/'bin'/'python',p)
            shutil.copymode(stage/'bin'/'python',p)
    # Record installation time on aliases themselves, including repaired links.
    # Do not follow links into another prefix when setting this metadata.
    for name in binary_names(stage):
        os.utime(stage/'bin'/name,None,follow_symlinks=False)
    os.utime(stage/'pyvenv.cfg',None)
    os.utime(stage/'bin',None)
    os.utime(stage,None)

def overlay_raw(stage, target_prefix, version):
    target_prefix=Path(target_prefix); mm=branch(version)
    def ignore(src,names):
        result=[]
        if Path(src).name=='bin':
            result=[n for n in names if not PYNAME.fullmatch(n) and not re.fullmatch(r'python[0-9.]+-config',n)]
        if Path(src).name=='python'+mm:
            result += [n for n in names if n in ('site-packages','dist-packages')]
        return result
    # Target executables replace symlinks rather than writing through them.
    for name in binary_names(target_prefix):
        p=stage/'bin'/name
        if p.exists() or p.is_symlink():p.unlink()
    def copy_installed(src,dst):
        result=shutil.copy2(src,dst)
        # Installation timestamps invalidate stale file/cache views when a
        # replacement was built before the current interpreter. This also
        # forces source-based bytecode cache validation after an overlay.
        os.utime(dst,None)
        return result
    shutil.copytree(str(target_prefix),str(stage),symlinks=True,dirs_exist_ok=True,ignore=ignore,
                    copy_function=copy_installed)
    # Relocate build metadata; package files and package entry points are preserved.
    metadata=list((stage/'lib').glob('python*/_sysconfigdata_*.py'))
    metadata+=list((stage/'lib').glob('python*/config-*/Makefile'))
    metadata+=list((stage/'lib').glob('pkgconfig/python*.pc'))
    metadata+=list((stage/'bin').glob('python*-config'))
    return metadata

def root_guard():
    if hasattr(os,'geteuid') and os.geteuid()==0:
        # A single root mapping identifies the disposable execution environment.
        # Host root remains disallowed for probing arbitrary user-owned binaries.
        try: mapping=Path('/proc/self/uid_map').read_text().split()
        except OSError: mapping=[]
        if mapping != ['0','0','1']:
            raise UpdateError('Run as the owner of the private Python installations, without sudo')

def protected(prefix):
    p=Path(prefix).resolve()
    return any(p==Path(root) or Path(root) in p.parents for root in ('/usr','/bin','/sbin','/lib','/lib64','/System','/opt/codex'))

def checks_for(prefix, config):
    checks=[]
    for pattern,items in (config or {}).items():
        if fnmatch.fnmatch(prefix,pattern): checks.extend(items)
    return checks

def load_targets(specs):
    targets={}
    for spec in specs:
        mm,sep,path=spec.partition('=')
        if not sep:raise UpdateError('Target format: 3.11=/absolute/path/bin/python3.11')
        info=probe(path)
        if branch(info['version'])!=mm:raise UpdateError('Cross-minor targets require an application migration')
        if info['prefix']!=info['base_prefix']:raise UpdateError('Target must be a raw CPython installation')
        floor=PATCH_FLOORS.get(mm)
        if floor and version_tuple(info['version'])<version_tuple(floor):
            raise UpdateError('Target is below the security policy floor '+floor)
        targets[mm]=info
    return targets

def make_plan(inventory,targets):
    plan=[]
    for env in inventory['environments']:
        item=dict(env); mm=branch(env['version']); target=targets.get(mm)
        item['eol']=EOL.get(mm); item['target']=target
        reason=None
        if env.get('managed') in ('conda','conda-package-cache'):reason='Conda-managed prefix/cache: use the Conda solver'
        elif protected(env['prefix']):reason='Distribution/runtime-managed prefix'
        elif env.get('referenced_only'):reason='Referenced base lies outside the scanned trees; add its path as a root'
        elif not target:reason='Target interpreter missing'
        elif len({branch(v) for v in env['versions']})!=1:reason='Multiple minor branches share a prefix'
        elif any(version_tuple(v)>version_tuple(target['version']) for v in env['versions']):reason='Downgrade refused'
        elif all(v==target['version'] for v in env['versions']) and not [e for e in env.get('binary_errors',[]) if Path(e['path']).name not in env.get('unresolved_aliases',[])]:reason='up_to_date'
        elif any(env[k]!=target[k] for k in ('soabi','machine','pointer_bits','shared')):reason='Interpreter ABI/build mismatch'
        elif env['kind']=='raw' and env['shared']:reason='Shared-library raw build needs a prefix-specific rebuild'
        elif canon(env['prefix']) in {canon(sys.prefix),canon(sys.base_prefix)}:reason='Running updater interpreter'
        elif env['kind']=='raw' and within(target['prefix'],env['prefix']):reason='Target is nested inside source prefix'
        elif not os.access(str(Path(env['prefix']).parent),os.W_OK):reason='Parent directory lacks write access'
        item['action']='skip' if reason else 'update';item['reason']=reason
        plan.append(item)
    return sorted(plan,key=lambda e:(e['kind']!='raw',e['prefix']))

def restore(entry,journal):
    prefix=Path(entry['prefix']);backup=Path(entry['backup'])
    if not backup.is_dir():raise UpdateError('Backup missing: '+str(backup))
    if prefix.is_symlink():raise UpdateError('Rollback prefix changed to a symlink')
    if prefix.exists() and entry.get('installed_identity'):
        st=prefix.stat()
        if [st.st_dev,st.st_ino]!=entry['installed_identity']:
            raise UpdateError('Rollback prefix identity changed')
    # Restore contents with a fresh installation time, keeping file modes and
    # skipping links to other prefixes. This avoids stale timestamp-based views.
    for root,dirs,files in os.walk(backup,followlinks=False):
        for name in dirs+files:
            p=Path(root)/name
            if p.lstat().st_uid==os.geteuid():os.utime(p,None,follow_symlinks=False)
    os.utime(backup,None)
    images=interpreter_images(backup)
    failed=prefix.with_name(prefix.name+MARKER+uuid.uuid4().hex+'.failed')
    if entry.get('publication')=='files':
        if prefix.exists():shutil.copytree(prefix,failed,symlinks=True)
        copy_into_existing(backup,prefix)
        publish_interpreters(prefix,images)
        entry['status']='rolled_back';entry['rolled_back_at']=utcnow();entry['failed_copy']=str(failed)
        atomic_json(journal['path'],journal)
        return
    if prefix.exists() or prefix.is_symlink():os.replace(prefix,failed)
    try:os.replace(backup,prefix)
    except BaseException:
        if failed.exists():os.replace(failed,prefix)
        raise
    publish_interpreters(prefix,images)
    entry['status']='rolled_back';entry['rolled_back_at']=utcnow();entry['failed_copy']=str(failed)
    atomic_json(journal['path'],journal)

def apply_plan(plan,journal_path,check_config,discovery_warnings=None):
    journal_path=Path(journal_path).absolute()
    if journal_path.exists():raise UpdateError('Journal exists; choose a new file or use rollback')
    journal=dict(schema=1,created=utcnow(),policy_date='2026-11-01',path=str(journal_path),entries=[],complete=False,
                 discovery_warnings=discovery_warnings or [],
                 unresolved_aliases=[dict(prefix=p['prefix'],name=name,reason='Nonstandard alias has no usable interpreter; preserved for review') for p in plan for name in p.get('unresolved_aliases',[])],
                 skipped=[dict(prefix=p['prefix'],reason=p['reason'],version=p['version']) for p in plan if p['action']=='skip'],
                 end_of_support=[dict(prefix=p['prefix'],branch=branch(p['version']),ended=p['eol']) for p in plan if p.get('eol')])
    atomic_json(journal_path,journal)
    # Snapshot before raw updates: symlink-based venvs can observe a new Python
    # as soon as their shared base changes.
    snapshots={};journal['failed_snapshots']=[]
    for item in plan:
        if item['action']=='update':
            try:snapshots[item['prefix']]=packages(item['binary'])
            except UpdateError as e:
                item['action']='skip';item['reason']='Snapshot failed: '+str(e)
                journal['skipped'].append(dict(prefix=item['prefix'],reason=item['reason'],version=item['version']))
                journal['failed_snapshots'].append(dict(prefix=item['prefix'],error=str(e)))
    failures=len(journal['failed_snapshots'])
    # Do not change the stdlib beneath a copied venv interpreter whose package
    # inventory could not be read. Healthy peers can use the separate target.
    blocked_bases={item['base_prefix'] for item in plan
                   if item['kind']=='venv' and item['prefix'] in
                   {f['prefix'] for f in journal['failed_snapshots']}}
    for item in plan:
        if item['kind']=='raw' and item['action']=='update' and item['prefix'] in blocked_bases:
            item['action']='skip';item['reason']='Dependent environment snapshot failed; raw base left unchanged'
            journal['skipped'].append(dict(prefix=item['prefix'],reason=item['reason'],version=item['version']))
    for item in plan:
        if item['action']!='update':
            emit('skip',prefix=item['prefix'],reason=item['reason']);continue
        prefix=Path(item['prefix']);target=item['target'];token=uuid.uuid4().hex
        stage=prefix.with_name(prefix.name+MARKER+token+'.stage')
        backup=prefix.with_name(prefix.name+MARKER+token+'.backup')
        entry=dict(prefix=str(prefix),stage=str(stage),backup=str(backup),kind=item['kind'],
                   old_version=item['version'],target_version=target['version'],
                   packages=snapshots[str(prefix)]['packages'],
                   console_scripts=snapshots[str(prefix)]['present_console_scripts'],
                   status='preparing',eol=item['eol'],publication='files')
        journal['entries'].append(entry);atomic_json(journal_path,journal)
        try:
            if prefix.is_symlink():raise UpdateError('Canonical prefix changed to a symlink during update')
            st=prefix.stat();entry['original_identity']=[st.st_dev,st.st_ino]
            if st.st_uid!=os.geteuid():raise UpdateError('Prefix is owned by another user')
            emit('prepare',prefix=str(prefix),target=target['version'])
            shutil.copytree(prefix,stage,symlinks=True)
            if item['kind']=='venv':
                base=item['base_prefix'];base_target=target['binary']
                # Prefer an updated existing raw prefix, preserving base-package
                # visibility for system-site-packages environments.
                candidate=Path(base)/'bin'/('python'+branch(target['version']))
                try:
                    if probe(candidate)['version']==target['version']:base_target=str(candidate)
                except UpdateError:pass
                patch_venv(stage,base_target,str(prefix))
            else:
                metadata=overlay_raw(stage,target['prefix'],target['version'])
                for path in metadata:
                    if path.is_symlink():continue
                    data=path.read_text()
                    path.write_text(data.replace(target['prefix'],str(prefix)))
            checks=checks_for(str(prefix),check_config)
            entry['staged_validation']=validate(stage,target['version'],entry['packages'],checks)
            entry['runtime_hashes']=runtime_hashes(stage,item['kind'])
            images=interpreter_images(stage)
            current=prefix.stat()
            if [current.st_dev,current.st_ino]!=entry['original_identity']:
                raise UpdateError('Prefix identity changed during staging')
            entry['status']='prepared';atomic_json(journal_path,journal)
            shutil.copytree(prefix,backup,symlinks=True)
            entry['status']='backed_up';atomic_json(journal_path,journal)
            copy_into_existing(stage,prefix)
            installed_stat=prefix.stat();entry['installed_identity']=[installed_stat.st_dev,installed_stat.st_ino]
            entry['status']='installed';atomic_json(journal_path,journal)
            publish_interpreters(prefix,images)
            entry['validation']=validate(prefix,target['version'],entry['packages'],checks,final=True,
                                         expected_scripts=entry['console_scripts'],expected_hashes=entry['runtime_hashes'])
            entry['status']='verified';entry['finished']=utcnow();atomic_json(journal_path,journal)
            emit('verified',prefix=str(prefix),version=target['version'],packages=len(entry['packages']))
            shutil.rmtree(stage)
        except BaseException as e:
            entry['error']=str(e);failures+=1
            if backup.is_dir():restore(entry,journal)
            else:entry['status']='failed_before_swap';atomic_json(journal_path,journal)
            emit('failed',prefix=str(prefix),reason=str(e),status=entry['status'])
            if isinstance(e,(KeyboardInterrupt,SystemExit)):raise
    # Recheck the complete batch after shared raw bases and dependent venvs have
    # finished; a per-prefix success cannot establish the final batch state.
    for entry in journal['entries']:
        if entry['status']!='verified':continue
        try:
            validate(entry['prefix'],entry['target_version'],entry['packages'],
                     checks_for(entry['prefix'],check_config),True,entry['console_scripts'],entry['runtime_hashes'])
            entry['batch_rechecked']=utcnow()
        except UpdateError as e:
            entry['status']='batch_recheck_failed';entry['error']=str(e);failures+=1
            emit('batch_recheck_failed',prefix=entry['prefix'],reason=str(e))
    journal['complete']=True;journal['finished']=utcnow();journal['failures']=failures
    atomic_json(journal_path,journal)
    return journal

def main():
    os.umask(0o077)
    parser=argparse.ArgumentParser(prog='update_python_envs.sh',description=__doc__)
    sub=parser.add_subparsers(dest='command',required=True)
    for name in ('scan','plan','apply'):
        p=sub.add_parser(name)
        p.add_argument('roots',nargs='+',help='Trusted private directories; directory links are followed')
        p.add_argument('--exclude',action='append',default=[])
        p.add_argument('--output',required=True,help='Inventory/plan JSON or apply journal')
        if name!='scan':
            p.add_argument('--target',action='append',required=True,help='MINOR=/path/to/patched/raw/bin/python')
        if name=='apply':p.add_argument('--checks',help='JSON: path glob -> argv smoke checks')
    p=sub.add_parser('verify');p.add_argument('journal');p.add_argument('--checks');p.add_argument('--output',required=True)
    p=sub.add_parser('rollback');p.add_argument('journal')
    args=parser.parse_args();root_guard()
    if args.command=='apply' and os.environ.get('PY_ENV_UPDATE_POST_VERIFY')=='1':
        args.command='verify';args.journal=args.output
        args.output=args.journal+'.post-verify.json'
    if args.command in ('scan','plan','apply'):
        excluded=list(args.exclude)
        targets=load_targets(args.target) if args.command!='scan' else {}
        excluded.extend(t['prefix'] for t in targets.values())
        inventory=scan(args.roots,excluded)
        if args.command=='scan':
            atomic_json(args.output,inventory)
            emit('scanned',environments=len(inventory['environments']),warnings=len(inventory['warnings']))
            return 0
        plan=make_plan(inventory,targets)
        if args.command=='plan':
            atomic_json(args.output,dict(inventory=inventory,plan=plan))
            emit('planned',updates=sum(p['action']=='update' for p in plan),skips=sum(p['action']=='skip' for p in plan))
            return 0
        checks=json.loads(Path(args.checks).read_text()) if args.checks else {}
        # A per-parent flock prevents simultaneous updater instances touching the
        # same prefixes, even when journal paths differ.
        locks=[]
        try:
            for parent in sorted({str(Path(p['prefix']).parent) for p in plan if p['action']=='update'}):
                f=open(Path(parent)/(MARKER+'lock'),'a')
                try:fcntl.flock(f,fcntl.LOCK_EX|fcntl.LOCK_NB)
                except BlockingIOError:raise UpdateError('Another updater holds '+parent)
                locks.append(f)
            journal=apply_plan(plan,args.output,checks,inventory['warnings'])
            return 1 if journal['failures'] else 0
        finally:
            for f in locks:f.close()
    journal=json.loads(Path(args.journal).read_text())
    if args.command=='rollback':
        journal['path']=str(Path(args.journal).absolute())
        # Reverse order restores venvs before their raw bases.
        for entry in reversed(journal['entries']):
            if entry['status'] in ('verified','installed','backed_up','prepared','batch_recheck_failed') and Path(entry['backup']).is_dir():
                restore(entry,journal);emit('rolled_back',prefix=entry['prefix'])
        return 0
    checks=json.loads(Path(args.checks).read_text()) if args.checks else {}
    results=[dict(prefix=f['prefix'],passed=False,error='Snapshot failed: '+f['error'])
             for f in journal.get('failed_snapshots',[])]
    for entry in journal['entries']:
        if entry['status']!='verified':
            results.append(dict(prefix=entry['prefix'],passed=False,error='Update status: '+entry['status']))
            continue
        try:
            result=validate(entry['prefix'],entry['target_version'],entry['packages'],checks_for(entry['prefix'],checks),True,
                            expected_scripts=entry.get('console_scripts',[]),expected_hashes=entry.get('runtime_hashes',{}))
            results.append(dict(prefix=entry['prefix'],passed=True,validation=result))
        except UpdateError as e:results.append(dict(prefix=entry['prefix'],passed=False,error=str(e)))
    atomic_json(args.output,dict(created=utcnow(),results=results))
    emit('verification',passed=sum(r['passed'] for r in results),failed=sum(not r['passed'] for r in results),
         unresolved_aliases=sum(len(r.get('validation',{}).get('unresolved_aliases',[])) for r in results))
    return 0 if all(r['passed'] for r in results) else 1

if __name__=='__main__':
    try:sys.exit(main())
    except UpdateError as e:emit('error',reason=str(e));sys.exit(2)

PY_ENV_UPDATE_ENGINE
}

# A fresh process checks the persisted state after the updating process exits.
# This also catches stale interpreter/link views outside that process.
if PY_ENV_UPDATE_POST_VERIFY=0 run_engine "$@"; then
  if [[ "${1:-}" == "apply" ]]; then
    PY_ENV_UPDATE_POST_VERIFY=1 run_engine "$@"
  fi
else
  exit "$?"
fi
