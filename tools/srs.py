#!/usr/bin/env python3
"""Build and release srs, GOKZ with the srs branches merged in.

  edit .srs.toml  the upstream tag and the branches to merge
  srs.py rebuild  rebuild srs-dev from .srs.toml
  srs.py check    check the current branch against the allowlist
  srs.py release  release srs-dev's build as srs
  srs.py dist     build the release zips of the srs tag at HEAD

rebuild resets srs-dev to the tag, then merges srs-version and the branches
into it, in order. .srs.toml looks like this:

  tag = "3.8.0"
  branches = [
      "syncable-replays",
      # "fix-replay-menu",
  ]

After resolving a merge conflict, commit it and rerun rebuild. The resolution
is reused from then on.

check compiles the current branch and the upstream code it's built on, and
fails if a plugin outside the allowlist or its gamedata differs, or if a plugin
was deleted. It changes nothing. The upstream code is the release the branch is
on, or for a branch started from upstream's dev, the commit it started from.

release runs check on srs-dev and adds the srs version suffix to every plugin
that differs from upstream. Then it tags srs-dev as the next srs release and
moves srs to it.

dist writes GOKZ-v<tag>.zip and GOKZ-v<tag>-upgrade.zip to dist/, with
the same files as upstream's release zips. The zips are reproducible: the same
tag and SourceMod build always give the same bytes. CI runs it when an srs tag
is pushed and attaches the zips to a GitHub release.

check, release and dist compile with spcomp64 from SMDIR, a SourceMod
scripting folder (the one with spcomp64 and include/ in it).
"""

import argparse
import fnmatch
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import tomllib
import zipfile
import zlib
from datetime import UTC, datetime
from pathlib import Path
from typing import cast

# The official exceptions to the rule against running modified plugins, then
# the non-gameplay plugins allowed by the later amendment.
ALLOWED = {'gokz-chat', 'gokz-errorboxfixer', 'gokz-hud', 'gokz-jumpbeam',
           'gokz-jumpstats', 'gokz-localdb', 'gokz-localranks',
           'gokz-measure', 'gokz-paint', 'gokz-playermodels', 'gokz-profile',
           'gokz-quiet', 'gokz-racing', 'gokz-replays', 'gokz-slayonend',
           'gokz-spec', 'gokz-tips'}

RECIPE = '.srs.toml'
UPSTREAM = 'refs/remotes/upstream/master'
UPSTREAM_DEV = 'refs/remotes/upstream/dev'
SCRIPTING = 'addons/sourcemod/scripting'
GAMEDATA = 'addons/sourcemod/gamedata'
PLUGINS = 'addons/sourcemod/plugins'
# Upstream's release zips leave these out by name at any depth, plus
# scripting. Theirs match .git exactly, so they ship .gitignore too.
DIST_EXCLUDED = ['sm', '*.md', '.git*', 'LICENSE', '*.zip', '*.fgd', 'tools']
SRS_INC = f'{SCRIPTING}/include/gokz/srs.inc'
VERSION_LINE = b'version = GOKZ_VERSION,'
SRS_VERSION_LINE = b'version = GOKZ_SRS_VERSION,'
GOKZ_INCLUDE = re.compile(rb'^#include <gokz[/>].*\n', re.MULTILINE)
SRS_INCLUDE = b'#include <gokz/srs>\n'
SRS_DEFINE = re.compile(
    r'(#define GOKZ_SRS_VERSION GOKZ_VERSION \.\.\. "-srs)(\d+)"')

SMX_MAGIC = 0x53504646
SMX_VERSION = 0x0102
SMX_COMPRESSION_ZLIB = 1

def git(*args: str) -> str:
    """Run git and return its trimmed stdout."""
    return subprocess.run(['git', *args], check=True, stdout=subprocess.PIPE,
                          text=True).stdout.strip()

def git_ok(*args: str) -> bool:
    """Run git quietly and return whether it succeeded."""
    return subprocess.run(['git', *args], capture_output=True).returncode == 0

def branch_exists(name: str) -> bool:
    """Return whether a local branch exists."""
    return git_ok('rev-parse', '--verify', '--quiet', f'refs/heads/{name}')

def tag_exists(name: str) -> bool:
    """Return whether a tag exists."""
    return git_ok('rev-parse', '--verify', '--quiet',
                  f'refs/tags/{name}^{{commit}}')

def is_upstream_release(tag: str) -> bool:
    """Return whether tag is a release tag on upstream's master."""
    return git_ok('merge-base', '--is-ancestor', f'refs/tags/{tag}', UPSTREAM)

def base_tag(rev: str) -> str | None:
    """Return the upstream release tag that rev was built on."""
    # First parent only, so tags reached through merged branches don't count.
    tag = subprocess.run(
        ['git', 'describe', '--tags', '--abbrev=0', '--first-parent',
         '--match', '[0-9]*.[0-9]*.[0-9]*', '--exclude', '*-*', rev],
        capture_output=True, text=True).stdout.strip()
    return tag if tag and is_upstream_release(tag) else None

def _u32(data: bytes, offset: int) -> int:
    return int.from_bytes(data[offset:offset + 4], 'little')

def behavior_sections(smx: bytes) -> dict[str, bytes]:
    """Return a compiled plugin's sections that can affect its behavior.

    That's every section except debug info, with the stack/heap reservation
    cut out of .data.
    """
    if (_u32(smx, 0) != SMX_MAGIC
            or int.from_bytes(smx[4:6], 'little') != SMX_VERSION
            or smx[6] != SMX_COMPRESSION_ZLIB):
        raise ValueError('unexpected SMX header')
    # Header offsets: 15 section count, 16 string table, 20 compressed data.
    data_offset = _u32(smx, 20)
    image = smx[:data_offset] + zlib.decompress(smx[data_offset:])
    string_table = _u32(image, 16)
    sections: dict[str, bytes] = {}
    for i in range(image[15]):
        entry = 24 + i * 12
        name_start = string_table + _u32(image, entry)
        name = image[name_start:image.index(b'\0', name_start)].decode()
        content = image[_u32(image, entry + 4):][:_u32(image, entry + 8)]
        if name == '.data':
            content = content[:4] + content[8:]
        if not name.startswith('.dbg.'):
            sections[name] = content
    return sections

def build(rev: str, out: Path, *,
          stamp: tuple[str, str]) -> dict[str, dict[str, bytes]]:
    """Export and compile rev in out, returning its plugins' sections.

    stamp is the date and time compiled into every plugin, in place of the
    compile time.
    """
    smdir = Path(os.environ.get('SMDIR') or '/nonexistent')
    if not (smdir / 'spcomp64').is_file() or not (smdir / 'include').is_dir():
        sys.exit('SMDIR must be a SourceMod scripting folder, the one with '
                 'spcomp64 and include/ in it')
    out.mkdir()
    archive = subprocess.run(['git', 'archive', rev], check=True,
                             capture_output=True).stdout
    subprocess.run(['tar', '-x', '-C', str(out)], input=archive, check=True)
    scripting = out / SCRIPTING
    (out / PLUGINS).mkdir(exist_ok=True)
    # spcomp records includes by the path it found them through, and its stack
    # estimate shifts with where it and its includes live. A copy at a
    # relative path, with relative paths everywhere, keeps both identical.
    (scripting / 'smdir').mkdir()
    shutil.copy2(smdir / 'spcomp64', scripting / 'smdir')
    shutil.copytree(smdir / 'include', scripting / 'smdir' / 'include')
    date, time = stamp
    plugins: dict[str, dict[str, bytes]] = {}
    for source in sorted(scripting.glob('gokz-*.sp')):
        smx = out / PLUGINS / f'{source.stem}.smx'
        result = subprocess.run(
            ['smdir/spcomp64', '-i', 'include', f'__DATE__="{date}"',
             f'__TIME__="{time}"', source.name,
             '-o', os.path.relpath(smx, scripting)],
            cwd=scripting, capture_output=True, text=True)
        if result.returncode != 0:
            sys.exit(f"{source.name} doesn't compile at {rev} (spcomp64 exit "
                     f'{result.returncode}):\n{result.stdout}{result.stderr}')
        plugins[source.stem] = behavior_sections(smx.read_bytes())
    return plugins

def rebuild() -> None:
    """Reset srs-dev to the recipe's tag and merge its branches into it."""
    if not Path(RECIPE).is_file():
        sys.exit(f'no {RECIPE}, see srs.py -h')
    try:
        recipe = tomllib.loads(Path(RECIPE).read_text())
    except tomllib.TOMLDecodeError as error:
        sys.exit(f'{RECIPE}: {error}')
    tag: object = recipe.get('tag')
    listed: object = recipe.get('branches')
    items = cast('list[object]', listed) if isinstance(listed, list) else []
    names = [name for name in items if isinstance(name, str)]
    if (not isinstance(tag, str) or not isinstance(listed, list)
            or len(names) != len(items)):
        sys.exit(f'{RECIPE} needs a tag and a list of branches, see srs.py '
                 '-h')
    branches = ['srs-version', *names]
    if not is_upstream_release(tag):
        sys.exit(f"{tag} isn't a release tag on upstream's master "
                 '(git fetch upstream --tags?)')
    for branch in branches:
        if not git_ok('rev-parse', '--verify', '--quiet',
                      f'{branch}^{{commit}}'):
            sys.exit(f'no such branch: {branch}')

    print(f'building srs-dev from {tag} with {", ".join(branches)}')
    git('switch', '--quiet', '-C', 'srs-dev', tag)
    # rerere replays conflict resolutions recorded by earlier rebuilds.
    rerere = ['-c', 'rerere.enabled=true', '-c', 'rerere.autoUpdate=true']
    for branch in branches:
        if not subprocess.run(['git', *rerere, 'merge', '--no-edit',
                               branch]).returncode:
            continue
        if git('diff', '--name-only', '--diff-filter=U'):
            sys.exit('resolve the conflict, commit it, then rerun')
        git(*rerere, 'commit', '--quiet', '--no-edit')
    print('srs-dev is built. Test it, then release it:\n'
          '  tools/srs.py check    (optional, just the allowlist check)\n'
          '  tools/srs.py release')

def check_base() -> str:
    """Return the upstream code HEAD should be compared with.

    That's the release HEAD is on, unless HEAD left upstream's dev after it.
    """
    tag = base_tag('HEAD')
    fork = git('merge-base', 'HEAD', UPSTREAM_DEV)
    # Release tags are never on dev, so a dev-based branch only reaches old
    # ones, which are ancestors of where it left dev.
    if tag is None or git_ok('merge-base', '--is-ancestor', tag, fork):
        return git('rev-parse', '--short', fork)
    return tag

def check(base: str) -> list[str]:
    """Return the plugins whose compiled code differs between base and HEAD.

    Exits if one outside the allowlist differs or was deleted, or if its
    gamedata differs.
    """
    print(f'comparing with upstream {base}')

    with tempfile.TemporaryDirectory() as temp:
        upstream = build(base, Path(temp, 'upstream'), stamp=('x', 'x'))
        srs = build('HEAD', Path(temp, 'srs'), stamp=('x', 'x'))
    changed = sorted(name for name in upstream.keys() | srs.keys()
                     if srs.get(name) != upstream.get(name))
    print('plugins that differ from upstream:', ', '.join(changed) or 'none')
    gamedata = git('diff', '--name-only', base, 'HEAD', '--',
                   GAMEDATA).splitlines()
    forbidden = [
        *(name for name in changed if name not in ALLOWED or name not in srs),
        *(path for path in gamedata
          if Path(path).name.split('.')[0] not in ALLOWED)]
    if forbidden:
        sys.exit("these aren't allowed to differ from upstream or be deleted: "
                 f'{", ".join(forbidden)}\n'
                 'undo the change, then rerun')
    return changed

def release() -> None:
    """Check srs-dev, tag it as the next srs release and move srs to it."""
    if not branch_exists('srs-dev'):
        sys.exit('no srs-dev branch, run rebuild first')
    git('switch', '--quiet', 'srs-dev')
    tag = base_tag('HEAD')
    if tag is None:
        sys.exit("can't find the upstream release srs-dev is built on")
    changed = check(tag)

    pending = [path for path in (Path(SCRIPTING, f'{name}.sp')
                                 for name in changed)
               if SRS_VERSION_LINE not in path.read_bytes()]
    for path in pending:
        source = path.read_bytes()
        if source.count(VERSION_LINE) != 1 or not GOKZ_INCLUDE.search(source):
            sys.exit(f'{path} no longer has exactly one GOKZ_VERSION myinfo '
                     'line and a gokz include, add the suffix by hand and '
                     'commit')
    for path in pending:
        source = path.read_bytes().replace(VERSION_LINE, SRS_VERSION_LINE)
        path.write_bytes(GOKZ_INCLUDE.sub(rb'\g<0>' + SRS_INCLUDE, source,
                                          count=1))
    if pending:
        git('commit', '--quiet', '-m',
            'Add the srs version suffix to plugins changed by srs',
            '--', *map(str, pending))
    released = git('tag', '--list', '*-srs*',
                   '--sort=-version:refname').splitlines()
    if released and git_ok('diff', '--quiet', released[0], 'HEAD', '--', '.',
                           f':(exclude){SRS_INC}'):
        sys.exit(f"srs-dev's build is the same as {released[0]}'s")

    srs_inc = Path(SRS_INC).read_text()
    define = SRS_DEFINE.search(srs_inc)
    if define is None:
        sys.exit(f"can't read the srs number from {SRS_INC}")
    number = int(define[2])
    while tag_exists(f'{tag}-srs{number}'):
        number += 1
    if number != int(define[2]):
        Path(SRS_INC).write_text(
            srs_inc.replace(define[0], f'{define[1]}{number}"'))
        git('commit', '--quiet', '-m', f'Bump the srs version to -srs{number}',
            '--', SRS_INC)

    name = f'{tag}-srs{number}'
    git('branch', '-f', 'srs', 'HEAD')
    git('tag', name)
    print(f'released {name}, push it with:\n'
          f'  git push --force-with-lease origin srs {name}')

def dist() -> None:
    """Write the release zips of the srs release tagged at HEAD."""
    name = subprocess.run(
        ['git', 'describe', '--tags', '--exact-match', '--match', '*-srs*',
         'HEAD'], capture_output=True, text=True).stdout.strip()
    if not name:
        sys.exit("HEAD isn't tagged as an srs release")

    # Everything time-dependent comes from the commit, so builds match.
    when = datetime.fromtimestamp(int(git('log', '-1', '--format=%ct')), UTC)
    with tempfile.TemporaryDirectory() as temp:
        tree = Path(temp, 'tree')
        _ = build('HEAD', tree, stamp=(when.strftime('%m/%d/%Y'),
                                       when.strftime('%H:%M:%S')))
        files = sorted(path.relative_to(tree) for path in tree.rglob('*')
                       if path.is_file())
        Path('dist').mkdir(exist_ok=True)
        # The upgrade zip also leaves out cfg, so it keeps server configs.
        for zip_name, excluded in ((f'dist/GOKZ-v{name}.zip', DIST_EXCLUDED),
                                   (f'dist/GOKZ-v{name}-upgrade.zip',
                                    [*DIST_EXCLUDED, 'cfg'])):
            with zipfile.ZipFile(zip_name, 'w', zipfile.ZIP_DEFLATED) as out:
                for path in files:
                    if (path.is_relative_to(SCRIPTING)
                            or any(fnmatch.fnmatch(part, pattern)
                                   for part in path.parts
                                   for pattern in excluded)):
                        continue
                    info = zipfile.ZipInfo(str(path), when.timetuple()[:6])
                    info.compress_type = zipfile.ZIP_DEFLATED
                    info.external_attr = (stat.S_IFREG | 0o644) << 16
                    out.writestr(info, (tree / path).read_bytes())
            print(f'wrote {zip_name}')

def main() -> None:
    """Run the subcommand named on the command line."""
    parser = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('command',
                        choices=['rebuild', 'check', 'release', 'dist'])
    args = parser.parse_args()
    command: str = args.command

    try:
        os.chdir(git('rev-parse', '--show-toplevel'))
        if git('status', '--porcelain', '--untracked-files=no'):
            sys.exit('uncommitted changes or a merge in progress, finish or '
                     'abort it first')
        if command == 'rebuild':
            rebuild()
        elif command == 'check':
            base = check_base()
            check(base)
            print(f'nothing outside the allowlist differs from {base}')
        elif command == 'release':
            release()
        else:
            dist()
    except subprocess.CalledProcessError as error:
        # The command already printed its error to stderr.
        sys.exit(error.returncode)

if __name__ == '__main__':
    main()
