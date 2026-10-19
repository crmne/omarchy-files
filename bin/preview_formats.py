"""Bounded preview decoders. Original files are passed as descriptors, never URLs."""
import base64
import io
import json
import os
import re
import selectors
import signal
import subprocess
import time
import zipfile
import xml.etree.ElementTree as ET

TEXT_LIMIT = 16384
MEDIA = {
    '.mp3':'mp3', '.wav':'wav', '.flac':'flac', '.ogg':'ogg', '.oga':'ogg', '.opus':'ogg',
    '.m4a':'mov', '.aac':'aac', '.aiff':'aiff', '.aif':'aiff', '.wma':'asf',
    '.mp4':'mov', '.mov':'mov', '.m4v':'mov', '.webm':'matroska', '.mkv':'matroska',
    '.avi':'avi', '.mpeg':'mpeg', '.mpg':'mpeg', '.ogv':'ogg', '.wmv':'asf',
}
RASTER = {'.png','.jpg','.jpeg','.webp','.gif','.bmp','.tif','.tiff','.avif','.ico','.icns','.jp2','.j2k','.ppm','.pgm','.pbm','.tga','.dds','.psd'}
ARCHIVES = {'.zip','.tar','.gz','.bz2','.xz','.tgz','.tbz2','.txz','.7z','.rar','.zst','.deb','.rpm'}
OFFICE = {'.docx','.odt','.ods','.odp','.xlsx','.pptx','.epub'}

def clean(text):
    return ''.join(c for c in text if c in '\n\t' or (ord(c)>=32 and not 127<=ord(c)<=159))[:TEXT_LIMIT]

def stop(proc):
    if proc.poll() is None:
        proc.kill()
    proc.wait()

def run(args, source, limit=2*1024*1024, seconds=3, prefix=False):
    source.seek(0)
    proc = subprocess.Popen(args, stdin=source, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                            env=dict(os.environ, OPENBLAS_NUM_THREADS='1', OMP_NUM_THREADS='1'))
    output = bytearray()
    deadline = time.monotonic()+seconds
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(proc.stdout, selectors.EVENT_READ)
            while True:
                remaining = deadline-time.monotonic()
                if remaining <= 0: raise ValueError('Preview decoder timed out.')
                if not selector.select(remaining): raise ValueError('Preview decoder timed out.')
                block = os.read(proc.stdout.fileno(), min(65536,limit+1-len(output)))
                if not block: break
                output.extend(block)
                if len(output)>limit:
                    if prefix: return bytes(output[:limit])
                    raise ValueError('Preview decoder exceeded its output limit.')
        if proc.wait(timeout=max(0.1,deadline-time.monotonic())):
            raise ValueError('This file could not be decoded for preview.')
        return bytes(output)
    finally:
        stop(proc)
        proc.stdout.close()

def png(data):
    return 'data:image/png;base64,'+base64.b64encode(data).decode()

def thumbnail(source):
    from PIL import Image, ImageOps
    import warnings
    Image.MAX_IMAGE_PIXELS=16_000_000
    warnings.simplefilter('error',Image.DecompressionBombWarning)
    image=Image.open(source)
    if image.width*image.height>16_000_000: raise ValueError('Image exceeds 16 million pixels.')
    image.thumbnail((512,512))
    image=ImageOps.exif_transpose(image).convert('RGBA')
    out=io.BytesIO();image.save(out,format='PNG')
    return png(out.getvalue())

def pdf(source, page):
    info=run(['pdfinfo','-'],source,limit=16384).decode('utf-8','replace')
    match=re.search(r'^Pages:\s+(\d+)',info,re.M)
    pages=int(match[1]) if match else 1
    page=max(1,min(page,pages))
    data=run(['pdftoppm','-f',str(page),'-l',str(page),'-singlefile','-scale-to','512','-png','-'],source)
    return dict(kind='pdf',image=png(data),page=page,pages=pages)

def media_input(ext):
    # fd is seekable and cannot open referenced network URLs or sidecar files.
    return ['-protocol_whitelist','fd,pipe','-f',MEDIA[ext],'-i','fd:']

def media_info(source, ext, position):
    info=json.loads(run(['ffprobe','-v','error','-threads','1',*media_input(ext),
        '-show_entries','format=duration:stream=codec_type,codec_name,width,height','-of','json'],source,limit=16384))
    duration=float(info.get('format',{}).get('duration',0) or 0)
    if not 0 <= duration <= 8640000: duration=0
    streams=info.get('streams',[])
    video=next((s for s in streams if s.get('codec_type')=='video'),None)
    audio=any(s.get('codec_type')=='audio' for s in streams)
    result=dict(kind='video' if video and ext in {'.mp4','.mov','.m4v','.webm','.mkv','.avi','.mpeg','.mpg','.ogv','.wmv'} else 'audio',duration=duration,audio=audio,
                position=max(0,min(position,max(0,duration-0.1))) if duration else 0)
    if video:
        if video.get('width',0)*video.get('height',0)>16_000_000:
            result['message']='Video exceeds the preview pixel limit.';return result
        data=run(['ffmpeg','-v','error','-nostdin','-threads','1',*media_input(ext),
            '-ss',str(result['position']),'-map','0:v:0','-frames:v','1','-an',
            '-vf','scale=512:512:force_original_aspect_ratio=decrease','-threads','1',
            '-f','image2pipe','-c:v','png','pipe:1'],source)
        result['image']=png(data)
    return result

def play(source, ext, position):
    # Only explicit playback calls this. Decode a finite excerpt to PCM first;
    # the audio player receives generated WAV, never an untrusted media URL.
    wav=run(['ffmpeg','-v','error','-nostdin','-threads','1',*media_input(ext),
        '-ss',str(position),'-t','30','-map','0:a:0','-vn','-ac','2','-ar','44100',
        '-f','wav','-c:a','pcm_s16le','pipe:1'],source,limit=6*1024*1024,seconds=4)
    proc=subprocess.Popen(['ffplay','-v','error','-nodisp','-autoexit','-threads','1',
        '-protocol_whitelist','pipe','-f','wav','-i','pipe:0'],stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        proc.communicate(wav,timeout=32)
        if proc.returncode: raise ValueError('Audio playback unavailable.')
    finally:
        stop(proc)
        proc.stdin.close()
    return dict(played=True)

def xml(data):
    upper=data.upper()
    if b'<!DOCTYPE' in upper or b'<!ENTITY' in upper: raise ValueError('Document declarations are not supported in previews.')
    return ET.fromstring(data)

def document(source, ext):
    with zipfile.ZipFile(source) as archive:
        names=archive.namelist()
        if len(names)>10000: raise ValueError('Document has too many entries.')
        if ext=='.docx': selected=['word/document.xml']
        elif ext in ('.odt','.ods','.odp'): selected=['content.xml']
        elif ext=='.pptx': selected=sorted((n for n in names if re.fullmatch(r'ppt/slides/slide\d+\.xml',n)),key=lambda n:int(re.search(r'(\d+)\.xml',n)[1]))[:10]
        elif ext=='.xlsx': selected=['xl/sharedStrings.xml','xl/worksheets/sheet1.xml']
        else: selected=[n for n in names if n.lower().endswith(('.xhtml','.html','.htm'))][:8]
        pieces=[]; shared=[]
        for name in selected:
            if name not in names:continue
            entry=archive.getinfo(name)
            if entry.file_size>256*1024: raise ValueError('Document section exceeds the preview limit.')
            tree=xml(archive.read(entry))
            if name=='xl/sharedStrings.xml':
                shared=[''.join(node.itertext()) for node in tree];continue
            if ext=='.xlsx':
                for row in tree.iter():
                    if row.tag.rsplit('}',1)[-1]!='row':continue
                    cells=[]
                    for cell in row:
                        value=''.join(cell.itertext())
                        if cell.get('t')=='s' and value.isdigit() and int(value)<len(shared):value=shared[int(value)]
                        cells.append(value)
                    pieces.append('\t'.join(cells))
            else: pieces.append('\n'.join(t.strip() for t in tree.itertext() if t.strip()))
            if sum(map(len,pieces))>TEXT_LIMIT:break
        return dict(kind='text',text=clean('\n\n'.join(pieces)),message='Document text preview; formatting omitted.')

def svg(source):
    data=source.read(1024*1024+1)
    if len(data)>1024*1024: raise ValueError('SVG exceeds 1 MiB.')
    tree=xml(data)
    # No scripts, embedded documents, imported styles, images or external URLs.
    for node in tree.iter():
        if node.tag.rsplit('}',1)[-1] in ('script','foreignObject','image','style'):
            raise ValueError('SVG contains embedded or active content.')
        for key,value in node.attrib.items():
            if key.rsplit('}',1)[-1]=='base' or (key.rsplit('}',1)[-1]=='href' and not value.startswith('#')):
                raise ValueError('SVG external references are not previewed.')
            if (key=='style' and ('\\' in value or '@' in value)) or '@import' in value.lower() or ('url(' in value.lower() and not re.fullmatch(r'url\(\s*#[\w.-]+\s*\)',value)):
                raise ValueError('SVG external styles are not previewed.')
    # Use an anonymous descriptor for sanitized bytes, without an external base URI.
    fd=os.memfd_create('files-svg')
    with os.fdopen(fd,'w+b') as f:
        f.write(ET.tostring(tree));f.seek(0)
        return dict(kind='image',image=png(run(['rsvg-convert','--keep-aspect-ratio','--width','512','--height','512'],f)))

def highlighted(text, name):
    result=dict(kind='text',text=text)
    if name.lower().endswith(('.txt','.log','.csv')): return result
    try:
        from pathlib import Path
        fd=os.memfd_create('files-highlight')
        with os.fdopen(fd,'w+b') as source:
            source.write(json.dumps(dict(text=text,name=name)).encode())
            reply=json.loads(run(['nvim','-u','NONE','-i','NONE','-n','--headless',
                '-l',str(Path(__file__).with_name('preview-highlight.lua'))],source,limit=256*1024,seconds=1))
        tokens=reply.get('tokens',[])
        if tokens and ''.join(t[1] for t in tokens)==text:
            result.update(tokens=tokens,language=reply.get('language',''),theme=reply.get('theme',''),background=reply.get('background',''))
    except (OSError, ValueError, subprocess.TimeoutExpired):
        pass  # Highlighting is optional; always retain the plain text preview.
    return result


def decode(source, ext, size, page=1, position=0, name=""):
    if ext in RASTER:
        if size>8*1024*1024:return dict(message='Image exceeds the 8 MiB preview limit.')
        return dict(kind='image',image=thumbnail(io.BytesIO(source.read(8*1024*1024+1))))
    if ext in MEDIA:
        if size>2*1024*1024*1024:return dict(message='Media exceeds the 2 GiB preview limit.')
        return media_info(source,ext,position)
    if ext in ('.heic','.heif'):
        if size>8*1024*1024:return dict(message='Image exceeds the 8 MiB preview limit.')
        info=json.loads(run(['ffprobe','-v','error','-protocol_whitelist','fd,pipe','-f','mov','-i','fd:',
                             '-show_entries','stream=width,height','-of','json'],source,limit=16384))
        if any(s.get('width',0)*s.get('height',0)>16_000_000 for s in info.get('streams',[])):
            return dict(message='Image exceeds the preview pixel limit.')
        data=run(['ffmpeg','-v','error','-nostdin','-threads','1','-protocol_whitelist','fd,pipe','-f','mov','-i','fd:',
                  '-frames:v','1','-vf','scale=512:512:force_original_aspect_ratio=decrease','-threads','1','-f','image2pipe','-c:v','png','pipe:1'],source)
        return dict(kind='image',image=png(data))
    if ext=='.pdf':
        if size>64*1024*1024:return dict(message='PDF exceeds the 64 MiB preview limit.')
        return pdf(source,page)
    if ext=='.svg':return svg(source)
    if ext in OFFICE:
        if size>32*1024*1024:return dict(message='Document exceeds the 32 MiB preview limit.')
        return document(source,ext)
    if ext in ARCHIVES:
        if size>128*1024*1024:return dict(message='Archive exceeds the 128 MiB preview limit.')
        # Listing only: no member is extracted to disk or executed.
        text=run(['bsdtar','-tf','-'],source,limit=TEXT_LIMIT,prefix=True).decode('utf-8','replace')
        return dict(kind='text',text=clean(text),message='Archive contents (no extraction).')
    data=source.read(TEXT_LIMIT)
    known_text=ext in {'.txt','.md','.log','.csv','.json','.xml','.yaml','.yml','.toml','.ini','.conf','.lua','.py','.rb','.js','.ts','.qml','.css','.html','.sh','.rs','.c','.h','.cpp','.sql','.srt','.vtt','.tex'}
    try:
        encoding='utf-16' if data.startswith((b'\xff\xfe',b'\xfe\xff')) else 'utf-8-sig'
        text=data.decode(encoding,errors='replace' if known_text else 'strict')
        if known_text and '\0' not in text:
            return dict(highlighted(clean(text), name),truncated=size>len(data))
        if '\0' not in text and not any(ord(c)<32 and c not in '\n\r\t' for c in text):
            return dict(highlighted(clean(text), name),truncated=size>len(data))
    except UnicodeDecodeError: pass
    return dict(message='No content preview for this format.')
