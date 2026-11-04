#!/usr/bin/env bash
set -euo pipefail
test "$(docker info --format '{{.CgroupDriver}}')" = systemd
printf '[Unit]\nDescription=Disposable isolated GEOInflow CI memory probe\n[Slice]\nMemoryAccounting=yes\nMemoryMax=900M\nMemorySwapMax=0\nCPUQuota=100%%\n' | sudo tee /run/systemd/system/geoinflowprobe.slice >/dev/null
sudo systemctl daemon-reload
sudo systemctl start geoinflowprobe.slice
sudo systemctl show geoinflowprobe.slice -p MemoryMax -p MemorySwapMax -p CPUQuotaPerSecUSec > output/runtime3-slice-limits.txt
docker network create geoinflow-probe >/dev/null
cleanup() {
  status=$?
  set +e
  printf '%s\n' "$status" > output/runtime3-probe-exit.txt
  for name in app db cache log analytics; do
    docker inspect --format '{{json .State}}' "probe-$name" > "output/runtime3-state-$name.json" 2>/dev/null
    docker logs "probe-$name" > "output/runtime3-$name.log" 2>&1
  done
  for f in memory.peak memory.current memory.events cpu.stat; do
    sudo cat "/sys/fs/cgroup/geoinflowprobe.slice/$f" > "output/runtime3-slice-$f.txt" 2>/dev/null
  done
  python3 - <<'REDACT'
from pathlib import Path
from urllib.parse import urlparse
import os
p=Path(os.environ['RUNNER_TEMP'])/'probe.env'
if p.exists():
 d=dict(x.split('=',1) for x in p.read_text().splitlines() if '=' in x)
 vals=[d.get('DATABASE_URL',''),d.get('APP_SECRET',''),d.get('TWO_FACTOR_ENCRYPTION_KEY',''),urlparse(d.get('DATABASE_URL','')).password or '']
 for f in Path('output').glob('*.log'):
  s=f.read_text(errors='replace')
  for v in vals:
   if v:s=s.replace(v,'[REDACTED_CI_SECRET]')
  f.write_text(s)
REDACT
  docker rm -fv probe-app probe-log probe-analytics probe-db probe-cache >/dev/null 2>&1
  docker network rm geoinflow-probe >/dev/null 2>&1
  sudo systemctl stop geoinflowprobe.slice
}
trap cleanup EXIT
# These credentials are generated solely for this disposable CI probe.
# No company credentials, real domains or visitor data enter this job.
password=$(openssl rand -hex 24)
secret=$(openssl rand -hex 32)
twofactor=$(openssl rand -hex 32)
for value in "$password" "$secret" "$twofactor"; do printf "::add-mask::%s\n" "$value"; done
printf 'DATABASE_URL=postgresql://probe:%s@probe-db:5432/probe\nAPP_SECRET=%s\nTWO_FACTOR_ENCRYPTION_KEY=%s\nLIEKAN_ANALYTICS_REDIS_URL=redis://probe-cache:6379\nLIEKAN_AI_ENABLED=false\nDISABLE_TELEMETRY=1\nNEXT_TELEMETRY_DISABLED=1\n' "$password" "$secret" "$twofactor" > "$RUNNER_TEMP/probe.env"
chmod 600 "$RUNNER_TEMP/probe.env"
docker run -d --name probe-db --network geoinflow-probe --cgroup-parent=geoinflowprobe.slice \
  --memory=256m --memory-swap=256m --cpus=.30 \
  -e POSTGRES_USER=probe -e POSTGRES_DB=probe -e POSTGRES_PASSWORD="$password" \
  postgres:16-alpine postgres -c shared_buffers=16MB -c work_mem=1MB \
  -c maintenance_work_mem=16MB -c max_connections=20 -c jit=off -c statement_timeout=10000 >/dev/null
docker run -d --name probe-cache --network geoinflow-probe --cgroup-parent=geoinflowprobe.slice \
  --memory=48m --memory-swap=48m --cpus=.10 \
  redis:7.4-alpine redis-server --maxmemory 16mb --maxmemory-policy allkeys-lru --save '' --appendonly no >/dev/null
ready=0
for i in {1..60}; do
  if docker exec probe-db pg_isready -U probe -d probe >/dev/null; then ready=1; break; fi
  sleep 2
done
test "$ready" = 1
docker run -d --name probe-app --network geoinflow-probe --cgroup-parent=geoinflowprobe.slice \
  --memory=384m --memory-swap=384m --cpus=.75 \
  -p 127.0.0.1:13002:3000 --env-file "$RUNNER_TEMP/probe.env" \
  -e NODE_OPTIONS=--max-old-space-size=256 "$APP_IMAGE" \
  sh -ec 'export PATH=/app/node_modules/.bin:$PATH; node scripts/liekan-schema-check.mjs --migrations-only --allow-pending; node scripts/check-db.js; node scripts/liekan-schema-check.mjs; node scripts/liekan-migrate.mjs; node scripts/liekan-queue-bootstrap.mjs; node scripts/update-tracker.js; exec node server.js' >/dev/null
ready=0
for i in {1..150}; do
  docker stats --no-stream --format '{{json .}}' probe-app probe-db probe-cache >> output/runtime3-startup-stats.jsonl
  if curl -fsS --max-time 5 http://127.0.0.1:13002/api/heartbeat > output/runtime3-heartbeat.json; then ready=1; break; fi
  test "$(docker inspect --format '{{.State.Running}}' probe-app)" = true || break
  sleep 4
done
docker logs probe-app > output/runtime3-startup-app.log 2>&1
test "$ready" = 1
docker run -d --name probe-log --network geoinflow-probe --cgroup-parent=geoinflowprobe.slice \
  --memory=256m --memory-swap=256m --cpus=.25 --env-file "$RUNNER_TEMP/probe.env" \
  -e NODE_OPTIONS=--max-old-space-size=128 "$APP_IMAGE" node dist/liekan-worker.mjs --pause-crawler-maintenance >/dev/null
docker run -d --name probe-analytics --network geoinflow-probe --cgroup-parent=geoinflowprobe.slice \
  --memory=192m --memory-swap=192m --cpus=.50 --env-file "$RUNNER_TEMP/probe.env" \
  -e NODE_OPTIONS=--max-old-space-size=128 "$APP_IMAGE" node dist/liekan-analytics-worker.mjs >/dev/null
for i in {1..12}; do
  curl -fsS --max-time 15 http://127.0.0.1:13002/login -o /dev/null
  curl -fsS --max-time 5 http://127.0.0.1:13002/api/heartbeat -o /dev/null
  docker stats --no-stream --format '{{json .}}' probe-app probe-db probe-cache probe-log probe-analytics >> output/runtime3-steady-stats.jsonl
  sleep 5
done
python3 - <<'QA'
import json,secrets,time,uuid,subprocess,urllib.request,urllib.error
from pathlib import Path
base='http://127.0.0.1:13002'; result={'synthetic_only':True,'human_stats_not_expected':True,'steps':[]}
def call(method,path,payload=None,token=None,extra=None):
 h={'Content-Type':'application/json','User-Agent':'GEOInflow-Synthetic-Probe/2'}
 if token:h['Authorization']='Bearer '+token
 if extra:h.update(extra)
 req=urllib.request.Request(base+path,method=method,headers=h,data=None if payload is None else json.dumps(payload).encode())
 try:
  with urllib.request.urlopen(req,timeout=90) as r:
   raw=r.read();result['steps'].append({'method':method,'path':path.split('?')[0],'status':r.status});return json.loads(raw) if raw else {}
 except urllib.error.HTTPError as e:
  result['steps'].append({'method':method,'path':path.split('?')[0],'status':e.code});raise RuntimeError('QA HTTP error; see status record') from None
try:
 login=call('POST','/api/auth/login',{'username':'admin','password':'liekan'});token=login['token'];password=secrets.token_urlsafe(32)
 call('POST','/api/me/password',{'currentPassword':'liekan','newPassword':password},token)
 login=call('POST','/api/auth/login',{'username':'admin','password':password});token=login['token']
 site=call('POST','/api/websites',{'name':'Synthetic CI QA','domain':'qa.example.invalid'},token);wid=str(uuid.UUID(site['id']))
 start=int(time.time()*1000)-60000;cache=None
 for name in [None,'qa_contact_open']:
  payload={'website':wid,'eventId':str(uuid.uuid4()),'hostname':'qa.example.invalid','url':'/qa','title':'Synthetic QA','language':'zh-CN','screen':'1440x900','referrer':''}
  if name:payload['name']=name
  sent=call('POST','/api/send',{'type':'event','payload':payload},extra={'x-umami-cache':cache} if cache else None);cache=sent.get('cache',cache)
 sql="SELECT coalesce(json_agg(row_to_json(q)), '[]'::json)::text FROM (SELECT event_type,event_name,count(*) AS count FROM website_event WHERE website_id='"+wid+"'::uuid GROUP BY event_type,event_name)q"
 out=subprocess.check_output(['docker','exec','probe-db','psql','-U','probe','-d','probe','-At','-c',sql],text=True)
 counts=json.loads(out);result['raw_event_counts']=counts
 assert sum(int(x['count']) for x in counts)>=2,'Synthetic sends were not persisted'
 result['stats']=call('GET',f'/api/websites/{wid}/stats?startAt={start}&endAt={int(time.time()*1000)+60000}&timezone=Asia%2FShanghai',token=token)
 result['passed']=True
finally:
 Path('output/runtime3-api-qa.json').write_text(json.dumps(result,indent=2))
QA

for name in app db cache log analytics; do
  docker inspect --format '{{json .State}}' "probe-$name" > "output/runtime3-state-$name.json"
done
for name in app db cache log analytics; do
  test "$(docker inspect --format '{{.State.Running}}' "probe-$name")" = true
  test "$(docker inspect --format '{{.State.OOMKilled}}' "probe-$name")" = false
done
docker exec probe-log node -e "const fs=require('fs');process.exit(Date.now()-fs.statSync('/tmp/liekan-worker-heartbeat').mtimeMs<120000?0:1)"
docker exec probe-analytics node -e "const fs=require('fs');process.exit(Date.now()-fs.statSync('/tmp/liekan-analytics-worker-heartbeat').mtimeMs<120000?0:1)"
printf '%s\n' 'startup_and_short_idle_probe_passed; not a traffic or production capacity guarantee' > output/runtime3-runtime-probe.txt
