#!/usr/bin/env python3
"""Package only public archive bytes; never read a deployment filesystem."""
import argparse, hashlib, io, json, lzma, os, pathlib, shutil, tarfile, tempfile

def digest(path):
 h=hashlib.sha256()
 with open(path,'rb') as f:
  for b in iter(lambda:f.read(1024*1024),b''):h.update(b)
 return h.hexdigest()

def safe_path(name):
 if name in ('.','./',''):return ''
 while name.startswith('./'):name=name[2:]
 p=pathlib.PurePosixPath(name)
 if p.is_absolute() or '..' in p.parts or '\x00' in name:raise ValueError('unsafe archive path')
 return str(p)

def meta(member):
 name=safe_path(member.name)
 if member.isfile():kind='file'
 elif member.isdir():kind='directory'
 elif member.issym():kind='symlink'
 elif member.islnk():kind='hardlink'
 else:raise ValueError('Unsupported archive node type: '+name)
 d={'path':name,'type':kind,'mode':member.mode&0o7777,'uid':member.uid,'gid':member.gid,'mtime':member.mtime,'size':member.size if kind=='file' else 0}
 if kind=='symlink':d['linkname']=member.linkname
 if kind=='hardlink':d['linkname']=safe_path(member.linkname)
 return d

def hash_stream(stream, spool=None):
 h=hashlib.sha256();n=0
 for block in iter(lambda:stream.read(1024*1024),b''):
  h.update(block);n+=len(block)
  if spool:spool.write(block)
 return h.hexdigest(),n

def write_json_xz(path,data):
 with lzma.open(path,'wt',encoding='utf-8',preset=6) as f:json.dump(data,f,separators=(',',':'),sort_keys=True);f.write('\n')

def build(base,target,out,base_sha,target_sha):
 assert digest(base)==base_sha,'Base archive hash mismatch'
 assert digest(target)==target_sha,'Target archive hash mismatch'
 out.mkdir(parents=True,exist_ok=False)
 old={}; by_content={}
 with tarfile.open(base,'r|*') as archive:
  for member in archive:
   m=meta(member);p=m['path']
   if not p:continue
   assert p not in old,'Duplicate base member'
   if m['type']=='file':
    m['sha256'],size=hash_stream(archive.extractfile(member));assert size==m['size']
    by_content.setdefault((m['sha256'],m['size']),p)
   old[p]=m
 entries=[];seen=set();changed=[];changed_bytes=0;reused_bytes=0
 delta=out/'rootfs-delta.tar.xz'
 with tarfile.open(target,'r|*') as archive, tarfile.open(delta,'w|xz',preset=6) as changes:
  for member in archive:
   m=meta(member);p=m['path']
   if not p:continue
   assert p not in seen,'Duplicate target member';seen.add(p)
   if m['type']=='file':
    with tempfile.TemporaryFile() as content:
     m['sha256'],size=hash_stream(archive.extractfile(member),content);assert size==m['size']
     previous=old.get(p)
     same_path=previous and previous['type']=='file' and previous['sha256']==m['sha256'] and previous['size']==size
     copy_from=p if same_path else by_content.get((m['sha256'],size))
     # A runtime updater may rewrite this small file; always use pristine target bytes.
     if p=='app/public/script.js':copy_from=None
     if copy_from:
      m['copy_from']=copy_from;reused_bytes+=size
     else:
      content.seek(0);clean=tarfile.TarInfo(p);clean.size=size;clean.mode=m['mode'];clean.uid=m['uid'];clean.gid=m['gid'];clean.mtime=m['mtime']
      changes.addfile(clean,content);changed.append(p);changed_bytes+=size
   entries.append(m)
 index={e['path']:e for e in entries}
 for e in entries:
  parent=pathlib.PurePosixPath(e['path']).parent
  while str(parent)!='.':
   assert str(parent) in index and index[str(parent)]['type']=='directory','Non-directory target ancestor'
   parent=parent.parent
  if e['type']=='hardlink':
   target_entry=index.get(e['linkname']);assert target_entry and target_entry['type']=='file','Hardlink must target a regular file'
   e['sha256']=target_entry['sha256'];e['size']=target_entry['size']
 # Independently re-read the finished delta and confirm full content coverage.
 delta_seen=set()
 with tarfile.open(delta,'r|xz') as archive:
  for member in archive:
   name=safe_path(member.name);assert member.isfile() and name in changed and name not in delta_seen
   actual,n=hash_stream(archive.extractfile(member));assert actual==index[name]['sha256'] and n==index[name]['size']
   delta_seen.add(name)
 assert delta_seen==set(changed)
 manifest={'schema_version':1,'source_commit':'6ba7c79d8d263ff620911fdccd90dd90be85dfb7','base_archive_sha256':base_sha,'target_archive_sha256':target_sha,'target_build_run':'41816372641','entries':sorted(entries,key=lambda e:e['path']),'changed_paths':sorted(changed),'deleted_paths':sorted(set(old)-seen),'all_target_content_covered':True}
 manifest_path=out/'rootfs-manifest.json.xz';write_json_xz(manifest_path,manifest)
 parts=[];part_size=4*1024*1024
 if delta.stat().st_size>part_size:
  with open(delta,'rb') as f:
   i=0
   while chunk:=f.read(part_size):
    p=out/('rootfs-delta.tar.xz.part%03d'%i);p.write_bytes(chunk);parts.append({'name':p.name,'bytes':len(chunk),'sha256':digest(p)});i+=1
 else:parts=[{'name':delta.name,'bytes':delta.stat().st_size,'sha256':digest(delta)}]
 summary={'schema_version':1,'source_commit':manifest['source_commit'],'base_archive_sha256':base_sha,'target_archive_sha256':target_sha,'target_build_run':'41816372641','manifest':{'name':manifest_path.name,'bytes':manifest_path.stat().st_size,'sha256':digest(manifest_path)},'delta':{'name':delta.name,'bytes':delta.stat().st_size,'sha256':digest(delta),'parts':parts},'entry_count':len(entries),'changed_file_count':len(changed),'changed_uncompressed_bytes':changed_bytes,'reused_uncompressed_bytes':reused_bytes,'deleted_path_count':len(manifest['deleted_paths']),'forced_pristine_paths':['app/public/script.js'],'verified_delta_contents':True,'scope':'Public never-started image archives only. No server files or visitor data. No deployment performed.'}
 (out/'delta-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
 if len(parts)>1:delta.unlink()
 with open(out/'delta-SHA256SUMS','w') as f:
  for p in sorted(out.iterdir()):
   if p.name!='delta-SHA256SUMS':f.write(digest(p)+'  '+p.name+'\n')
 return summary

if __name__=='__main__':
 parser=argparse.ArgumentParser();parser.add_argument('--base',type=pathlib.Path,required=True);parser.add_argument('--target',type=pathlib.Path,required=True);parser.add_argument('--output',type=pathlib.Path,required=True);parser.add_argument('--base-sha256',required=True);parser.add_argument('--target-sha256',required=True);a=parser.parse_args()
 print(json.dumps(build(a.base,a.target,a.output,a.base_sha256,a.target_sha256),indent=2))
