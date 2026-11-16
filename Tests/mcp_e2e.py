#!/usr/bin/env python3
"""Essai de bout en bout du serveur MCP : lance `mtapes-cli mcp` (stdio), pilote une vraie prise de l'écran principal
(l'appli mTAPES doit tourner avec « Pilotage par IA » coché) et vérifie la prise produite.
Usage : tests/mcp_e2e.py CHEMIN/mtapes-cli [--dev]"""
import json, subprocess, sys, time, os

cli = sys.argv[1]
args = [cli, "mcp"] + (["--dev"] if "--dev" in sys.argv else [])
p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
nid = 0
def rpc(method, params=None, notify=False):
    global nid
    msg = {"jsonrpc": "2.0", "method": method}
    if params is not None: msg["params"] = params
    if not notify:
        nid += 1; msg["id"] = nid
    p.stdin.write(json.dumps(msg) + "\n"); p.stdin.flush()
    if notify: return None
    return json.loads(p.stdout.readline())
def call(tool, **arguments):
    r = rpc("tools/call", {"name": tool, "arguments": arguments})["result"]
    text = r["content"][0]["text"]
    try: data = json.loads(text)
    except Exception: data = text
    return r["isError"], data
ok = True
def check(cond, what):
    global ok
    print(("  ✓ " if cond else "  ✗ ") + what)
    ok = ok and cond

init = rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "essai", "version": "1"}})
check(init["result"]["serverInfo"]["name"] == "mtapes" and "instructions" in init["result"], "initialize : nom du serveur et instructions")
rpc("notifications/initialized", notify=True)
tools = [t["name"] for t in rpc("tools/list")["result"]["tools"]]
check(sorted(tools) == sorted(["tapes_list_targets", "tapes_start", "tapes_mark", "tapes_status", "tapes_stop", "tapes_list", "tapes_finish", "tapes_export", "tapes_summary", "tapes_apply_plan"]), f"tools/list : {len(tools)} outils")
check(rpc("ping")["result"] == {}, "ping")
check("error" in rpc("inconnu"), "méthode inconnue : erreur JSON-RPC")

err, targets = call("tapes_list_targets", kind="display")
check(not err and isinstance(targets, list) and targets and "display" in targets[0], f"tapes_list_targets : {len(targets) if isinstance(targets, list) else targets} écran(s)")
err, e = call("tapes_mark", kind="click", x=1, y=1)
check(err, "tapes_mark sans prise : erreur claire")
err, d = call("tapes_start", target="display", name="essai MCP", client="essai", max_seconds=60)
check(not err and "tape_path" in d, f"tapes_start : {d.get('tape_path') if isinstance(d, dict) else d}")
err, e = call("tapes_start", target="display")
check(err, "second tapes_start : refusé pendant une prise")
t0 = time.time()
time.sleep(0.8)
err, m1 = call("tapes_mark", kind="chapter", label="Lancement")
err2, m2 = call("tapes_mark", kind="click", x=640, y=360, label="Choisir un dossier")
time.sleep(1.0)
err3, m3 = call("tapes_mark", kind="type", x=700, y=400, label="Nom de la sauvegarde")
check(not (err or err2 or err3) and m2.get("video_time_s") is not None, f"tapes_mark ×3 (temps vidéo {m2.get('video_time_s')} s)")
err, st = call("tapes_status")
check(not err and st["phase"] == "recording" and st["frames_written"] > 0, f"tapes_status : {st['phase']}, {st.get('frames_written')} images")
time.sleep(max(0, 3.5 - (time.time() - t0)))
err, stop = call("tapes_stop")
check(not err and stop["duration_s"] > 2.5 and stop["frames_refused"] == 0 and stop["events"] >= 3, f"tapes_stop : {stop.get('duration_s')} s, {stop.get('megabytes')} Mo, {stop.get('events')} marques")
err, lst = call("tapes_list", limit=3)
check(not err and lst and lst[0]["origin"] == "mcp" and lst[0]["state"] == "complete", "tapes_list : la prise est en tête, origine mcp")

path = stop["tape_path"]
err, fin = call("tapes_finish", tape_path=path, preset="release")
check(not err and fin["canvas"] == "1920x1080" and len(fin["captions"]) == 3 and len(fin["zooms"]) >= 1, f"tapes_finish : {len(fin['zooms'])} zoom(s), {len(fin['captions'])} légendes" if not err else str(fin))
err, sm = call("tapes_summary", tape_path=path, frames=2)
check(not err and sm["duration_s"] > 2.5 and len(sm["events"]) >= 3 and len(sm["frames"]) == 2 and all(0 <= e.get("x", 0) <= 1 or e.get("outside") for e in sm["events"]), f"tapes_summary : {len(sm['events'])} événements, {len(sm.get('frames', []))} images" if not err else str(sm))
err, ap = call("tapes_apply_plan", tape_path=path, preset="release", zooms=[{"from_s": 0.5, "to_s": 2.0, "scale": 2, "x": 0.5, "y": 0.5}], speeds=[], captions=[{"from_s": 0.5, "to_s": 2.0, "text": "Essai IA"}])
check(not err and len(ap["zooms"]) == 1 and ap["captions"][0]["text"] == "Essai IA" and ap["zooms"][0]["by"] == "ai", "tapes_apply_plan : plan de l'IA appliqué" if not err else str(ap))
pr = rpc("prompts/get", {"name": "edit_demo", "arguments": {"tape_path": path}})["result"]
check("tapes_apply_plan" in pr["messages"][0]["content"]["text"], "prompts/get edit_demo : guide de montage")
err, bad = call("tapes_finish", tape_path="/etc/passwd")
check(err, "tapes_finish refuse un chemin hors de ~/Movies/mTAPES")
err, exp = call("tapes_export", tape_path=path, destination="release")
check(not err and exp["size"] == "1920x1080" and exp["megabytes"] > 0.05, f"tapes_export : {exp.get('size')}, {exp.get('megabytes')} Mo en {exp.get('render_s')} s" if not err else str(exp))
if not err:
    d = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", exp["path"]], capture_output=True, text=True).stdout)
    check(abs(d - exp["duration_s"]) < 0.4 and d > 2, f"film exporté lisible, durée {d:.2f} s")
events = [json.loads(l) for l in open(os.path.join(path, "events.jsonl")) if l.strip()]
declared = [e for e in events if e["source"] == "declared"]
check([e["label"] for e in declared] == ["Lancement", "Choisir un dossier", "Nom de la sauvegarde"], "events.jsonl : 3 actions annoncées, dans l'ordre, avec leurs libellés")
check(all(a["t"] <= b["t"] for a, b in zip(events, events[1:])), "événements triés par temps")
meta = json.load(open(os.path.join(path, "meta.json")))
check(meta["origin"] == "mcp" and meta["client"] == "essai" and meta["state"] == "complete", "meta.json : origine mcp, client, état complet")
dur = float(subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", os.path.join(path, "raw.mov")], capture_output=True, text=True).stdout)
check(abs(dur - stop["duration_s"]) < 0.3, f"raw.mov lisible, durée {dur:.2f} s")
# Son : une prise avec le son du Mac (le micro demande une autorisation à l'utilisateur : non testé ici).
err, bad = call("tapes_start", target="display", audio="radio")
check(err, "tapes_start audio invalide : refusé")
err, d2 = call("tapes_start", target="display", name="essai son", client="essai", audio="system", max_seconds=60)
check(not err and "tape_path" in d2, "tapes_start audio=system")
if not err:
    sound = subprocess.Popen("sleep 1; afplay /System/Library/Sounds/Hero.aiff; afplay /System/Library/Sounds/Hero.aiff", shell=True)
    time.sleep(4.5)
    err, stop2 = call("tapes_stop")
    sound.wait()
    path2 = stop2["tape_path"]
    meta2 = json.load(open(os.path.join(path2, "meta.json")))
    tr = meta2.get("audio") or []
    check(len(tr) == 1 and tr[0]["kind"] == "system" and os.path.exists(os.path.join(path2, tr[0]["file"])), "meta.json : piste son du Mac enregistrée")
    if tr:
        check(abs(tr[0]["start"] - meta2["firstFramePTS"]) < 0.5, f"son calé sur la vidéo (écart {1000 * (tr[0]['start'] - meta2['firstFramePTS']):.0f} ms)")
        err, sm2 = call("tapes_summary", tape_path=path2)
        check(not err and sm2.get("audio") == ["system"], "tapes_summary : indique le son")
        err, exp2 = call("tapes_export", tape_path=path2, destination="short")
        streams = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_type", "-of", "csv=p=0", exp2["path"]], capture_output=True, text=True).stdout.split() if not err else []
        check("audio" in streams and "video" in streams, "film exporté : piste son AAC présente")
        vol = subprocess.run(["ffmpeg", "-v", "info", "-i", exp2["path"], "-af", "volumedetect", "-vn", "-f", "null", "-"], capture_output=True, text=True).stderr
        mx = [float(l.split("max_volume:")[1].split()[0]) for l in vol.splitlines() if "max_volume" in l]
        check(mx and mx[0] > -40, f"le son exporté n'est pas muet (crête {mx[0] if mx else '?'} dB)")
# Couleurs : Display P3 (étiquettes du brut et du film ; GIF toujours sRGB).
err, bad = call("tapes_start", target="display", color="rec2020")
check(err, "tapes_start color invalide : refusé")
err, d3 = call("tapes_start", target="display", name="essai P3", client="essai", color="p3", max_seconds=60)
check(not err and "tape_path" in d3, "tapes_start color=p3")
if not err:
    time.sleep(2.5)
    err, stop3 = call("tapes_stop")
    path3 = stop3["tape_path"]
    meta3 = json.load(open(os.path.join(path3, "meta.json")))
    check(meta3.get("colorSpace") == "p3", "meta.json : colorSpace p3")
    def prim(f): return subprocess.run(["ffprobe", "-v", "error", "-select_streams", "v", "-show_entries", "stream=color_primaries", "-of", "csv=p=0", f], capture_output=True, text=True).stdout.strip()
    check(prim(os.path.join(path3, "raw.mov")) == "smpte432", "brut étiqueté Display P3 (smpte432)")
    err, exp3 = call("tapes_export", tape_path=path3, destination="release")
    check(not err and prim(exp3["path"]) == "smpte432", "film exporté étiqueté Display P3")
p.stdin.close(); p.wait(timeout=5)
print("TAPE", path)
print("RÉSULTAT :", "OK" if ok else "ÉCHEC")
sys.exit(0 if ok else 1)
