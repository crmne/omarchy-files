import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HELPER = Path(__file__).resolve().parents[1]/'bin/files-support'
loader = importlib.machinery.SourceFileLoader('support', str(HELPER))
spec = importlib.util.spec_from_loader(loader.name, loader)
support = importlib.util.module_from_spec(spec)
loader.exec_module(support)

class SupportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.home = Path(self.temp.name)
        self.env = patch.dict(os.environ, HOME=str(self.home), XDG_CONFIG_HOME=str(self.home/'.config'))
        self.env.start()
    def tearDown(self):
        self.env.stop(); self.temp.cleanup()
    def preview(self, path):
        result = subprocess.run([str(HELPER), 'preview'], capture_output=True, text=True, timeout=5,
                                env=dict(os.environ, CRMNE_FILES_PATH=str(path), CRMNE_FILES_ROOT=str(self.home)))
        return json.loads(result.stdout)
    def test_text_is_bounded_and_plain(self):
        p = self.home/'test.txt'; p.write_bytes(b'<script>bad()</script>\x1b\0')
        self.assertEqual(self.preview(p)['result']['kind'], 'metadata')
        p.write_bytes(b'<script>bad()</script>\x1b'+b'x'*20000)
        result = self.preview(p)['result']
        self.assertTrue(result['truncated']); self.assertLessEqual(len(result['text']),16384)
        self.assertNotIn('\x1b',result['text']); self.assertIn('<script>',result['text'])
    def test_symlink_fifo_and_outside_root_are_not_read(self):
        target=self.home/'notes.txt';target.write_text('private')
        link=self.home/'link.txt';link.symlink_to(target)
        self.assertEqual(self.preview(link)['result']['kind'],'metadata')
        fifo=self.home/'pipe.txt';os.mkfifo(fifo)
        self.assertEqual(self.preview(fifo)['result']['kind'],'metadata')
        self.assertEqual(self.preview(Path('/etc/passwd'))['result']['kind'],'metadata')
    def test_thumbnail_is_bounded_png(self):
        from PIL import Image
        p=self.home/'image.jpg';Image.new('RGB',(1024,768),'red').save(p)
        result=self.preview(p)['result']
        self.assertEqual(result['kind'],'image');self.assertTrue(result['image'].startswith('data:image/png;base64,'))
    def test_invalid_image_fails_without_crashing_caller(self):
        p=self.home/'broken.png';p.write_bytes(b'not an image')
        self.assertFalse(self.preview(p)['ok'])
    def test_settings_are_private_and_do_not_change_hyprland_without_opt_in(self):
        cfg=support.defaults();cfg['root']=str(self.home);cfg['shortcut']='SUPER + P'
        with patch.object(support,'apply_shortcut',side_effect=AssertionError('unexpected config write')):
            saved=support.save(cfg)
        self.assertEqual(saved['shortcut'],support.DEFAULT_SHORTCUT)
        self.assertEqual(support.settings_path().stat().st_mode & 0o777,0o600)
    def test_shortcut_rejects_injection(self):
        for value in ['SUPER + SPACE"); os.execute("bad")','SUPER + SUPER + P','ALT + UNKNOWN']:
            with self.assertRaises(ValueError): support.shortcut(value)
    def binding(self):
        p=self.home/'.config/hypr/bindings.lua';p.parent.mkdir(parents=True)
        p.write_text('o.bind("SUPER + CTRL + ALT + SPACE", "Find files", "omarchy-shell shell toggle crmne.files")\n-- Keep this\n')
        return p
    def test_conflict_preserves_config(self):
        p=self.binding();before=p.read_bytes()
        def hypr(*args):
            return json.dumps([dict(modmask=64,key='P',description='Another action')]) if args==('-j','binds') else ''
        with patch.object(support,'hypr',hypr),self.assertRaises(ValueError): support.apply_shortcut('SUPER + P')
        self.assertEqual(before,p.read_bytes())
    def test_apply_migrates_owned_binding_and_adds_include_once(self):
        p=self.binding()
        with patch.object(support,'hypr',lambda *args: '[]' if args==('-j','binds') else ''):
            support.apply_shortcut('SUPER + P');support.apply_shortcut('SUPER + P')
        self.assertEqual(p.read_text().count(support.INCLUDE),1)
        self.assertIn('-- Keep this',p.read_text());self.assertNotIn('o.bind(',p.read_text())
        self.assertIn('SUPER + P',p.with_name('crmne-files.lua').read_text())
    def test_failed_reload_rolls_back(self):
        p=self.binding();before=p.read_bytes();calls=0
        def hypr(*args):
            nonlocal calls
            if args==('-j','binds'): return '[]'
            if args==('configerrors',):
                calls+=1
                return '' if calls==1 else 'syntax error'
            return ''
        with patch.object(support,'hypr',hypr),self.assertRaises(ValueError):support.apply_shortcut('SUPER + P')
        self.assertEqual(before,p.read_bytes());self.assertFalse(p.with_name('crmne-files.lua').exists())

if __name__=='__main__':unittest.main()
