#!/usr/bin/env python3
"""Métriques AMP pour le collecteur textfile du node exporter.

  amp-metrics          état des instances, ports de jeu, CPU/RAM des processus (chaque minute)
  amp-metrics sizes    taille des instances et de leurs sauvegardes (toutes les 15 minutes)

Tout est redécouvert à chaque passage : une nouvelle instance AMP est suivie sans configuration.
Le label s'appelle amp_instance, « instance » étant réservé par Prometheus.
"""
import json
import os
import re
import sys
import time

AMP_HOME = os.environ.get("AMP_HOME", "/home/amp")
OUT_DIR = os.environ.get("TEXTFILE_DIR", "/var/lib/prometheus/node-exporter")
DATA = os.path.join(AMP_HOME, ".ampdata")
INSTANCES_DIR = os.path.join(DATA, "instances")
CLK_TCK = os.sysconf("SC_CLK_TCK")
PAGE_SIZE = os.sysconf("SC_PAGE_SIZE")
# Protocole des ports dans la config AMP : 0 TCP, 1 UDP, 2 les deux (on teste TCP)
PROTOCOLS = {0: "tcp", 1: "udp", 2: "tcp"}
# Processus d'enrobage (tmux, shells) : ni serveur de jeu ni AMP
WRAPPERS = {"tmux", "tmux: server", "bash", "sh", "screen", "sudo"}


def esc(value):
    return str(value).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def metric(name, labels, value):
    lbl = ",".join(f'{k}="{esc(v)}"' for k, v in labels.items())
    return f"{name}{{{lbl}}} {value}"


def write(filename, lines):
    path = os.path.join(OUT_DIR, filename)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)  # atomique : le node exporter ne lit jamais un fichier à moitié écrit


def load_instances():
    try:
        with open(os.path.join(DATA, "instances.json"), encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return []


def read_kvp(path):
    values = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for raw in f:
                key, sep, val = raw.rstrip("\n").partition("=")
                if sep:
                    values[key.strip()] = val.strip()
    except OSError:
        pass
    return values


def declared_ports(inst):
    """Ports de jeu déclarés par l'instance : (port, protocole, nom, type)."""
    folder = os.path.join(INSTANCES_DIR, inst["InstanceName"])
    ports = {}

    def add(port, proto, name, kind):
        try:
            port = int(port)
        except (TypeError, ValueError):
            return
        if port > 0 and (port, proto) not in ports:
            ports[(port, proto)] = (name, kind)

    # Ports ajoutés à la main dans AMP (Dynmap, chat vocal…) : suivis, sans alerte.
    # En premier : AMP les recopie aussi dans MonitorPorts, ils y garderaient le type « game »
    for p in inst.get("CustomPorts") or []:
        add(p.get("PortNumber"), PROTOCOLS.get(p.get("Protocol"), "tcp"), p.get("Description") or "Custom", "custom")
    # Minecraft (et modules du même modèle) : <Module>.PortNumber
    for key, val in read_kvp(os.path.join(folder, "MinecraftModule.kvp")).items():
        if key == "Minecraft.PortNumber":
            add(val, "tcp", "Game Port", "game")
    # Modules génériques (jeux Steam…) : liste App.Ports, le port principal est le port de jeu
    generic = read_kvp(os.path.join(folder, "GenericModule.kvp"))
    primary = generic.get("App.PrimaryApplicationPortRef")
    try:
        for p in json.loads(generic.get("App.Ports", "[]")):
            kind = "game" if p.get("Ref") == primary else "app"
            add(p.get("Port"), PROTOCOLS.get(p.get("Protocol"), "tcp"), p.get("Name", "Port"), kind)
    except ValueError:
        pass
    # Ports suivis par AMP (autres modules), hors SFTP qui appartient au panneau
    try:
        monitored = json.loads(inst.get("DeploymentArgs", {}).get("Core.Monitoring.MonitorPorts", "[]"))
    except ValueError:
        monitored = []
    for p in monitored:
        if "sftp" not in str(p.get("Name", "")).lower():
            add(p.get("Port"), PROTOCOLS.get(p.get("Protocol"), "tcp"), p.get("Name", "Port"), "game")
    return [(port, proto, name, kind) for (port, proto), (name, kind) in sorted(ports.items())]


def listening_ports():
    """Ports en écoute sur la machine, lus dans /proc/net (TCP : état LISTEN, UDP : socket liée)."""
    found = set()
    for proto, files, state in (("tcp", ("tcp", "tcp6"), "0A"), ("udp", ("udp", "udp6"), "07")):
        for name in files:
            try:
                with open(f"/proc/net/{name}") as f:
                    next(f)
                    for row in f:
                        cols = row.split()
                        if cols[3] == state:
                            found.add((int(cols[1].rsplit(":", 1)[1], 16), proto))
            except OSError:
                continue
    return found


def amp_processes(amp_uid):
    """Processus de l'utilisateur amp, rattachés à leur instance par leur dossier de travail."""
    pattern = re.compile(re.escape(INSTANCES_DIR) + r"/([^/\x00]+)")
    procs = []
    for pid in filter(str.isdigit, os.listdir("/proc")):
        base = f"/proc/{pid}"
        try:
            if os.stat(base).st_uid != amp_uid:
                continue
            with open(f"{base}/comm") as f:
                comm = f.read().strip()
            with open(f"{base}/stat") as f:
                fields = f.read().rsplit(")", 1)[1].split()
            where = [os.readlink(f"{base}/cwd")]
            with open(f"{base}/cmdline", "rb") as f:
                where.append(f.read().replace(b"\x00", b" ").decode(errors="replace"))
        except (OSError, IndexError):
            continue  # processus terminé entre-temps
        if comm in WRAPPERS:
            continue
        match = next((m for m in map(pattern.search, where) if m), None)
        if comm.startswith("AMP_"):
            kind = "amp"
        elif "steamcmd" in comm.lower():
            kind = "steamcmd"
        else:
            kind = "app"
        procs.append({
            "instance": match.group(1) if match else "AMP",
            "process": comm,
            "kind": kind,
            # champs 14/15 de /proc/<pid>/stat (utime, stime), 24 (rss) ; décalés de 2 après le « ) »
            "cpu": (int(fields[11]) + int(fields[12])) / CLK_TCK,
            "rss": int(fields[21]) * PAGE_SIZE,
        })
    return procs


def collect_state():
    try:
        import pwd
        amp_uid = pwd.getpwnam("amp").pw_uid
    except KeyError:
        amp_uid = -1
    instances = load_instances()
    listening = listening_ports()
    procs = amp_processes(amp_uid)

    lines = [
        "# HELP amp_instance_info Instance AMP déclarée.",
        "# TYPE amp_instance_info gauge",
        "# HELP amp_instance_up Processus AMP de l'instance en marche.",
        "# TYPE amp_instance_up gauge",
        "# HELP amp_instance_autostart Instance démarrée avec AMP.",
        "# TYPE amp_instance_autostart gauge",
        "# HELP amp_app_running Serveur de jeu de l'instance en marche.",
        "# TYPE amp_app_running gauge",
        "# HELP amp_port_listening Port déclaré par l'instance en écoute.",
        "# TYPE amp_port_listening gauge",
    ]
    for inst in instances:
        name = inst["InstanceName"]
        mine = [p for p in procs if p["instance"] == name]
        lines.append(metric("amp_instance_info", {
            "amp_instance": name, "friendly_name": inst.get("FriendlyName") or name,
            "module": inst.get("Module", "")}, 1))
        lines.append(metric("amp_instance_up", {"amp_instance": name}, int(any(p["kind"] == "amp" for p in mine))))
        lines.append(metric("amp_instance_autostart", {"amp_instance": name}, int(bool(inst.get("DaemonAutostart")))))
        lines.append(metric("amp_app_running", {"amp_instance": name}, int(any(p["kind"] == "app" for p in mine))))
        for port, proto, pname, kind in declared_ports(inst):
            lines.append(metric("amp_port_listening", {
                "amp_instance": name, "port": port, "protocol": proto, "name": pname, "kind": kind},
                int((port, proto) in listening)))

    # CPU/RAM regroupés par instance et nom de processus (java, steamcmd, AMP_Linux…)
    totals = {}
    for p in procs:
        key = (p["instance"], p["process"], p["kind"])
        cpu, rss, count = totals.get(key, (0.0, 0, 0))
        totals[key] = (cpu + p["cpu"], rss + p["rss"], count + 1)
    lines += [
        "# HELP amp_process_cpu_seconds_total Temps CPU des processus AMP (par instance et processus).",
        "# TYPE amp_process_cpu_seconds_total counter",
        "# HELP amp_process_memory_bytes Mémoire résidente des processus AMP.",
        "# TYPE amp_process_memory_bytes gauge",
        "# HELP amp_process_count Nombre de processus.",
        "# TYPE amp_process_count gauge",
    ]
    for (inst, proc, kind), (cpu, rss, count) in sorted(totals.items()):
        labels = {"amp_instance": inst, "process": proc, "kind": kind}
        lines.append(metric("amp_process_cpu_seconds_total", labels, f"{cpu:.2f}"))
        lines.append(metric("amp_process_memory_bytes", labels, rss))
        lines.append(metric("amp_process_count", labels, count))

    # un nom par fichier : le node exporter refuse une même métrique répartie sur deux fichiers
    lines += ["# TYPE amp_state_last_run_timestamp_seconds gauge",
              f"amp_state_last_run_timestamp_seconds {int(time.time())}"]
    write("amp.prom", lines)


def disk_usage(path, skip=None):
    """Espace réellement occupé (blocs), nombre de fichiers et date du plus récent."""
    total = files = 0
    newest = 0.0
    for root, dirs, names in os.walk(path):
        if skip and root == path:
            dirs[:] = [d for d in dirs if d != skip]
        for n in names:
            try:
                st = os.lstat(os.path.join(root, n))
            except OSError:
                continue
            total += st.st_blocks * 512
            files += 1
            newest = max(newest, st.st_mtime)
    return total, files, newest


def collect_sizes():
    lines = [
        "# HELP amp_instance_size_bytes Espace occupé par l'instance, sauvegardes AMP exclues.",
        "# TYPE amp_instance_size_bytes gauge",
        "# HELP amp_backups_size_bytes Espace occupé par les sauvegardes AMP de l'instance.",
        "# TYPE amp_backups_size_bytes gauge",
        "# HELP amp_backups_files Nombre de fichiers de sauvegarde.",
        "# TYPE amp_backups_files gauge",
        "# HELP amp_backup_last_timestamp_seconds Date de la sauvegarde la plus récente.",
        "# TYPE amp_backup_last_timestamp_seconds gauge",
    ]
    for inst in load_instances():
        name = inst["InstanceName"]
        folder = os.path.join(INSTANCES_DIR, name)
        size, _, _ = disk_usage(folder, skip="Backups")
        bsize, bfiles, newest = disk_usage(os.path.join(folder, "Backups"))
        labels = {"amp_instance": name}
        lines.append(metric("amp_instance_size_bytes", labels, size))
        lines.append(metric("amp_backups_size_bytes", labels, bsize))
        lines.append(metric("amp_backups_files", labels, bfiles))
        if bfiles:
            lines.append(metric("amp_backup_last_timestamp_seconds", labels, int(newest)))
    # un nom par fichier : le node exporter refuse une même métrique répartie sur deux fichiers
    lines += ["# TYPE amp_sizes_last_run_timestamp_seconds gauge",
              f"amp_sizes_last_run_timestamp_seconds {int(time.time())}"]
    write("amp-sizes.prom", lines)


if __name__ == "__main__":
    if sys.argv[1:] == ["sizes"]:
        collect_sizes()
    else:
        collect_state()
