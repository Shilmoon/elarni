"""A commit of the working tree for the remote check runners."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def git(*args, env=None):
    return subprocess.run(['git', '-C', str(ROOT), *args], check=True, capture_output=True, text=True,
                          env=env).stdout.strip()


def snapshot():
    """Return a commit holding the working tree, untracked files included, without touching the index."""
    if not git('status', '--porcelain', '--untracked-files=normal'):
        return git('rev-parse', 'HEAD')
    with tempfile.TemporaryDirectory() as directory:
        index = Path(directory) / 'index'
        shutil.copy(ROOT / git('rev-parse', '--git-path', 'index'), index)  # its stat cache avoids rehashing
        env = dict(os.environ, GIT_INDEX_FILE=str(index), GIT_AUTHOR_NAME='snapshot', GIT_AUTHOR_EMAIL='snapshot@localhost',
                   GIT_COMMITTER_NAME='snapshot', GIT_COMMITTER_EMAIL='snapshot@localhost')
        git('add', '-A', env=env)
        tree = git('write-tree', env=env)
        return git('commit-tree', tree, '-p', 'HEAD', '-m', 'Check snapshot', env=env)
