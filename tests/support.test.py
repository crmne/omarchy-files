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
    def preview(self, path, **extra):
        result = subprocess.run([str(HELPER), 'preview'], capture_output=True, text=True, timeout=10,
                                env=dict(os.environ, CRMNE_FILES_PATH=str(path), CRMNE_FILES_ROOT=str(self.home), **extra))
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
    def test_pdf_page_navigation(self):
        from PIL import Image
        p=self.home/'pages.pdf'
        Image.new('RGB',(200,200),'red').save(p,save_all=True,append_images=[Image.new('RGB',(200,200),'blue')])
        first=self.preview(p)['result']
        second=self.preview(p,CRMNE_FILES_PAGE='2')['result']
        self.assertEqual(first['kind'],'pdf');self.assertEqual(first['pages'],2)
        self.assertEqual(second['page'],2);self.assertNotEqual(first['image'],second['image'])
    def test_audio_metadata_and_explicit_playback(self):
        import wave
        p=self.home/'tone.wav'
        with wave.open(str(p),'wb') as f:
            f.setnchannels(1);f.setsampwidth(2);f.setframerate(8000);f.writeframes(b'\0\0'*800)
        result=self.preview(p)
        self.assertTrue(result['ok'],result)
        self.assertEqual(result['result']['kind'],'audio');self.assertTrue(result['result']['audio'])
        self.assertAlmostEqual(result['result']['duration'],0.1,places=2)
        # SDL's dummy audio driver exercises decoding and playback without sound.
        played=subprocess.run([str(HELPER),'play'],capture_output=True,text=True,timeout=8,
            env=dict(os.environ,CRMNE_FILES_PATH=str(p),CRMNE_FILES_ROOT=str(self.home),SDL_AUDIODRIVER='dummy'))
        self.assertEqual(played.returncode,0,played.stdout+played.stderr)
    def test_video_frame_preview(self):
        p=self.home/'frames.avi'
        # Mux synthetic raw pixels; this performs no video rendering or encoding.
        subprocess.run(['ffmpeg','-v','error','-f','rawvideo','-pixel_format','yuv420p','-video_size','32x32','-framerate','1',
            '-i','pipe:0','-c:v','copy','-tag:v','I420',str(p)],input=b'\x40'*1024+b'\x80'*512+b'\xc0'*1024+b'\x80'*512,check=True)
        result=self.preview(p)
        self.assertTrue(result['ok'],result);self.assertEqual(result['result']['kind'],'video')
        self.assertTrue(result['result']['image'].startswith('data:image/png;base64,'))
        second=self.preview(p,CRMNE_FILES_POSITION='1')['result']
        self.assertNotEqual(result['result']['image'],second['image'])
    def test_office_and_archive_text_without_extraction(self):
        import zipfile
        p=self.home/'letter.docx'
        with zipfile.ZipFile(p,'w') as z:z.writestr('word/document.xml','<document><p><t>Demo letter</t></p></document>')
        self.assertIn('Demo letter',self.preview(p)['result']['text'])
        p=self.home/'sample.zip'
        with zipfile.ZipFile(p,'w') as z:z.writestr('../../do-not-extract.txt','private')
        self.assertIn('do-not-extract',self.preview(p)['result']['text'])
        self.assertFalse((self.home.parent/'do-not-extract.txt').exists())
    def test_svg_rejects_external_references_and_entities(self):
        p=self.home/'drawing.svg'
        p.write_text('<svg xmlns="http://www.w3.org/2000/svg" width="100" height="100"><rect width="100" height="100" fill="red"/></svg>')
        result=self.preview(p);self.assertTrue(result['ok'],result)
        self.assertEqual(result['result']['kind'],'image')
        p.write_text('<svg xmlns="http://www.w3.org/2000/svg"><image href="file:///etc/passwd"/></svg>')
        self.assertFalse(self.preview(p)['ok'])
        p.write_text('<!DOCTYPE svg [<!ENTITY x SYSTEM "file:///etc/passwd">]><svg>&x;</svg>')
        self.assertFalse(self.preview(p)['ok'])
    def test_unknown_utf8_text_and_utf16_text(self):
        p=self.home/'source.go';p.write_text('package main')
        self.assertEqual(self.preview(p)['result']['kind'],'text')
        p=self.home/'notes.txt';p.write_bytes('Hello world'.encode('utf-16'))
        self.assertEqual(self.preview(p)['result']['text'],'Hello world')
    def test_syntax_tokens_preserve_source_and_cache_invalidates_on_edit(self):
        p=self.home/'demo.py';source='def hello():\n    return "<img src=\"file:///etc/passwd\">"\n'
        p.write_text(source)
        result=self.preview(p)['result']
        self.assertEqual(result['language'],'python')
        self.assertEqual(''.join(t[1] for t in result['tokens']),source)
        self.assertIn('keyword',[t[0] for t in result['tokens']])
        cached=self.preview(p,CRMNE_FILES_FINGERPRINT=result['fingerprint'])['result']
        self.assertTrue(cached['unchanged']);self.assertNotIn('tokens',cached)
        p.write_text('print("changed")')
        changed=self.preview(p,CRMNE_FILES_FINGERPRINT=result['fingerprint'])['result']
        self.assertNotIn('unchanged',changed);self.assertIn('changed',changed['text'])
    def test_neovim_ignores_user_config_and_preserves_unicode(self):
        config=self.home/'.config/nvim/init.lua';config.parent.mkdir(parents=True)
        config.write_text('error("User configuration must not run")')
        p=self.home/'unicode.py'
        source='# vim: set filetype=sh:\nname = "café 🌻"\n'
        p.write_text(source)
        result=self.preview(p)['result']
        self.assertEqual(result['language'],'python')
        self.assertEqual(''.join(t[1] for t in result['tokens']),source)
    def test_neovim_theme_colors_and_cache_follow_theme_changes(self):
        theme=self.home/'.config/nvim/lua/plugins/theme.lua'
        theme.parent.mkdir(parents=True)
        def write_theme(color):
            theme.write_text('vim.api.nvim_set_hl(0,"String",{fg="'+color+'"})\n'
                'vim.api.nvim_set_hl(0,"Normal",{fg="#ddeeff",bg="#112233"})\n'
                'vim.g.colors_name="preview-test"\nreturn {}\n')
        write_theme('#123456')
        p=self.home/'code.py';p.write_text('value = "hello"\n')
        result=self.preview(p)['result']
        self.assertEqual(result['theme'],'preview-test')
        self.assertEqual(result['background'],'#112233')
        self.assertIn('#123456',[t[2] for t in result['tokens'] if t[0]=='string'])
        write_theme('#abcdef')
        result2=self.preview(p,CRMNE_FILES_FINGERPRINT=result['fingerprint'])['result']
        self.assertNotIn('unchanged',result2)
        self.assertIn('#abcdef',[t[2] for t in result2['tokens'] if t[0]=='string'])
    def test_missing_neovim_keeps_plain_text(self):
        p=self.home/'code.py';p.write_text('return 42')
        result=self.preview(p,PATH='/nonexistent')['result']
        self.assertEqual(result['text'],'return 42')
        self.assertNotIn('tokens',result)
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
