#!/usr/bin/env python3
"""Read-only Linux resource sampling for the dedicated voice laboratory host.

Run beside capacity_probe.py. No application credentials, media or user IDs are
collected. Values describe this host, not a cloud bandwidth quota or an SLA.
"""
import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import statistics
import re
import subprocess
import sys
import time


def cpu_ticks():
    values = [int(v) for v in Path('/proc/stat').read_text().splitlines()[0].split()[1:9]]
    return sum(values), values[3] + values[4], values


def network():
    result = [0, 0, 0, 0]
    for line in Path('/proc/net/dev').read_text().splitlines()[2:]:
        name, data = line.split(':', 1)
        if name.strip() == 'lo' or name.strip().startswith(('veth', 'docker', 'br-')):
            continue
        values = [int(v) for v in data.split()]
        for i, value in enumerate((values[0], values[8], values[2] + values[3], values[10] + values[11])):
            result[i] += value
    return result


def process_resources(pid):
    try:
        fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
        rss = int(fields[21]) * os.sysconf('SC_PAGE_SIZE')
        return {'ticks': int(fields[11]) + int(fields[12]), 'rssBytes': rss,
                'openFileDescriptors': len(list(Path(f'/proc/{pid}/fd').iterdir()))}
    except (OSError, ValueError, IndexError):
        return None


def collect(seconds, interval, stop_file=None):
    services = ('livekit-lab', 'livekit-lab-api', 'nginx', 'haproxy')
    pids = {}
    for name in services:
        value = subprocess.run(['systemctl', 'show', name, '-p', 'MainPID', '--value'],
                               capture_output=True, text=True, timeout=3).stdout.strip()
        pids[name] = int(value or 0)
    samples = []
    previous_cpu, previous_net = cpu_ticks(), network()
    previous_process = {name: process_resources(pid) for name, pid in pids.items()}
    started = previous_time = time.monotonic()
    while time.monotonic() - started < seconds and not (stop_file and stop_file.exists()):
        time.sleep(min(interval, max(0, seconds - (time.monotonic() - started))))
        now = time.monotonic()
        elapsed = now - previous_time
        current_cpu, current_net = cpu_ticks(), network()
        total = current_cpu[0] - previous_cpu[0]
        idle = current_cpu[1] - previous_cpu[1]
        mem = {line.split(':')[0]: int(line.split()[1]) * 1024
               for line in Path('/proc/meminfo').read_text().splitlines()}
        row = {'at': datetime.now(timezone.utc).isoformat(), 'elapsedSeconds': round(now - started, 2),
               'cpuPercent': round(100 * (total - idle) / total, 2) if total else None,
               'cpuModesPercent': {
                   name: round(100 * (current_cpu[2][index] - previous_cpu[2][index]) / total, 2)
                   if total else None
                   for index, name in enumerate(('user', 'nice', 'system', 'idle', 'iowait', 'irq', 'softirq', 'steal'))},
               'memoryUsedBytes': mem['MemTotal'] - mem['MemAvailable'],
               'memoryTotalBytes': mem['MemTotal'],
               'memoryPercent': round(100 * (1 - mem['MemAvailable'] / mem['MemTotal']), 2),
               'receiveMbps': round(8 * (current_net[0] - previous_net[0]) / elapsed / 1e6, 3),
               'transmitMbps': round(8 * (current_net[1] - previous_net[1]) / elapsed / 1e6, 3),
               'receiveErrorsAndDrops': max(0, current_net[2] - previous_net[2]),
               'transmitErrorsAndDrops': max(0, current_net[3] - previous_net[3]),
               'loadAverage': os.getloadavg(), 'processes': {}}
        for name, pid in pids.items():
            value = process_resources(pid)
            previous = previous_process[name]
            if value:
                value['cpuPercentOneCore'] = (round(100 * (value['ticks'] - previous['ticks']) /
                    os.sysconf('SC_CLK_TCK') / elapsed, 2) if previous else None)
                previous_process[name] = dict(value)
                value.pop('ticks')
            row['processes'][name] = value
        samples.append(row)
        previous_cpu, previous_net, previous_time = current_cpu, current_net, now
    summary = {}
    for key in ('cpuPercent', 'memoryPercent', 'receiveMbps', 'transmitMbps'):
        values = sorted(sample[key] for sample in samples if sample[key] is not None)
        summary[key] = {'median': statistics.median(values),
                        'p95': values[max(0, math.ceil(0.95 * len(values)) - 1)],
                        'maximum': max(values)} if values else None
    return {'server': 'furby.top', 'cpuCores': os.cpu_count(),
            'durationSeconds': round(time.monotonic() - started, 2), 'maximumDurationSeconds': seconds,
            'intervalSeconds': interval, 'percentileMethod': 'nearest rank: ceil(0.95*n)-1',
            'summary': summary, 'samples': samples}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds', type=int, default=180)
    parser.add_argument('--interval', type=float, default=2)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--stop-file', type=Path,
                        help='Optional dedicated /tmp/kiki-capacity-* marker on the laboratory host; create it to finish sampling.')
    parser.add_argument('--collect', action='store_true', help=argparse.SUPPRESS)
    args = parser.parse_args()
    if not 10 <= args.seconds <= 1800 or not 1 <= args.interval <= 15:
        parser.error('seconds must be 10..1800 and interval 1..15')
    if args.stop_file and not re.fullmatch(r'/tmp/kiki-capacity-[A-Za-z0-9._-]+', str(args.stop_file)):
        parser.error('stop-file must be a dedicated /tmp/kiki-capacity-* marker')
    if args.collect:
        print(json.dumps(collect(args.seconds, args.interval, args.stop_file)))
        return
    if not args.output:
        parser.error('--output is required')
    command = ['ssh', '-F', str(Path(__file__).with_name('ssh_config')), 'furby-livekit-lab',
               f'python3 - --collect --seconds {args.seconds} --interval {args.interval}'
               + (f' --stop-file {args.stop_file}' if args.stop_file else '')]
    result = subprocess.run(command, input=Path(__file__).read_text(), capture_output=True,
                            text=True, timeout=args.seconds + 30)
    if result.returncode:
        raise SystemExit('Dedicated laboratory resource sampler failed; no credentials were collected.')
    data = json.loads(result.stdout)
    args.output.write_text(json.dumps(data, indent=2) + '\n')
    print(json.dumps({'output': str(args.output), 'summary': data['summary']}))


if __name__ == '__main__':
    main()
