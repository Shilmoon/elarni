"""Process-level checks of the portable Linux bundle's desktop registration."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent.parent


@unittest.skipUnless(sys.platform != 'win32' and os.geteuid() != 0, 'install-desktop runs as a desktop user')
class InstallDesktopTest(unittest.TestCase):
    def test_remove_drops_only_this_bundles_login_entry(self):
        with tempfile.TemporaryDirectory() as temporary:
            home = Path(temporary).resolve()
            bundle = home / 'my $bundle'
            (bundle / 'data').mkdir(parents=True)
            shutil.copy(ROOT / 'linux' / 'install-desktop', bundle)
            shutil.copy(ROOT / 'linux' / 'com.elarni.Elarni.desktop', bundle)
            (bundle / 'data' / 'elarni.png').write_bytes(b'png')
            environment = dict(os.environ, HOME=str(home), XDG_DATA_HOME=str(home / 'data'), XDG_CONFIG_HOME=str(home / 'config'))
            autostart = home / 'config' / 'autostart' / 'com.elarni.Elarni.desktop'
            autostart.parent.mkdir(parents=True)

            def install(*arguments):
                subprocess.run([sys.executable, str(bundle / 'install-desktop'), *arguments], env=environment, check=True, capture_output=True)

            # As desktop_host.cc writes it: Exec quoting, then key-file escaping.
            install()
            autostart.write_text('[Desktop Entry]\nType=Application\nName=Elarni\nExec="' + str(bundle).replace('$', '\\\\$') + '/elarni"\n')
            install('--remove')
            self.assertFalse(autostart.exists())
            other = '[Desktop Entry]\nType=Application\nName=Elarni\nExec="/opt/elarni/elarni"\n'
            install()
            autostart.write_text(other)
            install('--remove')
            self.assertEqual(autostart.read_text(), other)


if __name__ == '__main__':
    unittest.main()
