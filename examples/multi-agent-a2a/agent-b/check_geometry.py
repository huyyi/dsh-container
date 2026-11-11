#!/usr/bin/env python3
"""仓库二维扇形覆盖检查；部署数据只从 B 的 AGENTS.md 读取。"""
import argparse
import itertools
import json
import math
from pathlib import Path
import re

EPS = 1e-9


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def load_warehouse(path):
    blocks = re.findall(r"```warehouse-json\s*\n(.*?)\n```", Path(path).read_text(), re.S)
    if len(blocks) != 1:
        raise ValueError("Expected exactly one warehouse-json block")
    data = json.loads(blocks[0])
    grid = data['matrix']
    if not grid or not all(isinstance(row, str) and len(row) == len(grid[0]) for row in grid):
        raise ValueError("Matrix must be rectangular")
    if any(ch not in '#.' for row in grid for ch in row):
        raise ValueError("Matrix supports only # and .")
    if data['cellSizeMeters'] != 1:
        raise ValueError("This demo requires 1-meter cells")
    height, width = len(grid), len(grid[0])
    if width < 3 or height < 3 or any(ch != '#' for ch in grid[0] + grid[-1]) or any(row[0] != '#' or row[-1] != '#' for row in grid):
        raise ValueError("Expected a closed perimeter wall")
    ids = set()
    for sensor in data['sensors']:
        sid = sensor['id']
        if sid in ids:
            raise ValueError("Duplicate sensor ID")
        ids.add(sid)
        x, y = sensor['position']
        lo, hi = sensor['rotation']
        if not all(number(v) for v in [x, y, lo, hi, sensor['heading'], sensor['fov'], sensor['range']]):
            raise ValueError("Sensor fields must be finite numbers")
        if not ((x in (1, width - 1) and 1 < y < height - 1) or (y in (1, height - 1) and 1 < x < width - 1)):
            raise ValueError("Sensor must be on an inner perimeter face")
        if not (30 <= sensor['fov'] <= 90 and sensor['range'] > 0 and lo <= sensor['heading'] <= hi and 0 <= hi - lo < 360):
            raise ValueError("Invalid opening, range or mechanical interval")
        if not isinstance(sensor['available'], bool):
            raise ValueError("available must be boolean")
    if not ids:
        raise ValueError("No sensors configured")
    return data


def intersects_box(start, end, box):
    # 线段与闭矩形的 slab 相交；忽略传感器起点与安装墙面的单点接触。
    enter, leave = 0.0, 1.0
    for p, q, low, high in zip(start, end, box[:2], box[2:]):
        delta = q - p
        if abs(delta) < EPS:
            if p < low - EPS or p > high + EPS:
                return False
        else:
            a, b = sorted(((low - p) / delta, (high - p) / delta))
            enter, leave = max(enter, a), min(leave, b)
            if enter > leave + EPS:
                return False
    return leave > EPS and enter < 1 - EPS


def sees(sensor, heading, point, obstacles):
    if not sensor['available']:
        return False
    x, y = sensor['position']
    dx, dy = point[0] - x, point[1] - y
    if math.hypot(dx, dy) > sensor['range'] + EPS:
        return False
    bearing = math.degrees(math.atan2(dy, dx))
    error = (bearing - heading + 180) % 360 - 180
    if abs(error) > sensor['fov'] / 2 + EPS:
        return False
    return not any(intersects_box((x, y), point, box) for box in obstacles)


def legal_heading(sensor, requested, previous):
    if not number(requested):
        raise ValueError(f"{sensor['id']}: heading must be finite")
    lo, hi = sensor['rotation']
    normalized = requested % 360
    candidates = [normalized + 360 * k for k in range(math.floor((lo - normalized) / 360), math.ceil((hi - normalized) / 360) + 1)]
    candidates = [v for v in candidates if lo - EPS <= v <= hi + EPS]
    if not candidates:
        raise ValueError(f"{sensor['id']}: heading {requested} outside rotation {lo}..{hi}")
    return min(candidates, key=lambda v: abs(v - previous))


def check(data, plan, target, radius):
    if not all(number(v) for v in [*target, radius]) or radius < 0:
        raise ValueError("Target/radius must be finite; radius must be non-negative")
    grid, sensors = data['matrix'], data['sensors']
    height, width = len(grid), len(grid[0])
    if not (0 <= target[0] < width and 0 <= target[1] < height):
        raise ValueError("Target is outside the warehouse coordinate frame")
    if plan.get('warehouseId') != data['warehouseId']:
        raise ValueError("Warehouse ID mismatch")
    rounds = plan.get('rounds')
    if not isinstance(rounds, list) or not 1 <= len(rounds) <= 20:
        raise ValueError("Expected 1..20 scan rounds")
    free, obstacles = [], []
    for row, line in enumerate(grid):
        for col, char in enumerate(line):
            y = height - row - 1
            if char == '.':
                free.append((col + .5, y + .5))
            else:
                obstacles.append((col, y, col + 1, y + 1))
    priority = {p for p in free if math.dist(p, target) <= radius + EPS}
    if not priority:
        raise ValueError("Priority region contains no walkable cell centers")
    previous = {s['id']: s['heading'] for s in sensors}
    ever_seen, ever_dual, reports = set(), set(), []
    for scan in rounds:
        headings = scan['headings']
        if set(headings) != set(previous):
            raise ValueError("Every round must specify all sensor IDs exactly")
        motions = []
        for sensor in sensors:
            sid = sensor['id']
            heading = legal_heading(sensor, headings[sid], previous[sid])
            delta = heading - previous[sid]
            if not sensor['available'] and abs(delta) > EPS:
                raise ValueError(f"{sid}: cannot adjust an unavailable sensor")
            motions.append({'sensorId': sid, 'from': previous[sid], 'to': heading,
                            'signedDelta': delta, 'direction': 'CCW' if delta > EPS else 'CW' if delta < -EPS else 'hold'})
            previous[sid] = heading
        coverage = {p: [s['id'] for s in sensors if sees(s, previous[s['id']], p, obstacles)] for p in free}
        seen = {p for p, ids in coverage.items() if ids}
        dual = {p for p, ids in coverage.items() if len(ids) >= 2}
        pairs = {}
        for point in sorted(priority):
            for pair in itertools.combinations(coverage[point], 2):
                pairs.setdefault('+'.join(pair), []).append(point)
        reports.append({'name': scan.get('name', f'round-{len(reports) + 1}'), 'motions': motions,
                        'coveredCells': len(seen), 'dualCells': len(dual),
                        'priorityCovered': len(priority & seen), 'priorityDual': len(priority & dual),
                        'priorityPairs': pairs, 'priorityBlind': sorted(priority - seen),
                        'priorityNotDual': sorted(priority - dual)})
        ever_seen |= seen
        # 联合覆盖必须发生在同一轮，不把不同轮的单站观测拼成双站覆盖。
        ever_dual |= dual
    return {'warehouseId': data['warehouseId'], 'model': '2D cell centers; opaque walls/racks; no observations',
            'walkableCells': len(free), 'priorityCells': len(priority), 'rounds': reports,
            'summary': {'everCovered': len(ever_seen), 'everDualSameRound': len(ever_dual),
                        'priorityEverCovered': len(priority & ever_seen), 'priorityEverDualSameRound': len(priority & ever_dual),
                        'neverCovered': sorted(set(free) - ever_seen), 'neverDualSameRound': sorted(set(free) - ever_dual),
                        'priorityNeverCovered': sorted(priority - ever_seen), 'priorityNeverDualSameRound': sorted(priority - ever_dual)}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--agents', required=True)
    parser.add_argument('--plan', required=True)
    parser.add_argument('--target', nargs=2, type=float, required=True)
    parser.add_argument('--radius', type=float, required=True)
    args = parser.parse_args()
    try:
        report = check(load_warehouse(args.agents), json.loads(Path(args.plan).read_text()), args.target, args.radius)
    except (ValueError, KeyError, TypeError, OSError) as error:
        parser.exit(2, f'Invalid plan/deployment: {error}\n')
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
