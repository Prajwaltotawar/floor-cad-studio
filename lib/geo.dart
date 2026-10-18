import 'dart:math';
import 'package:flutter/material.dart';
import 'model.dart';

Offset closestOnSeg(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final l2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (l2 < 1e-9) return a;
  var t = ((p.dx - a.dx) * ab.dx + (p.dy - a.dy) * ab.dy) / l2;
  t = t < 0 ? 0 : (t > 1 ? 1 : t);
  return a + ab * t;
}

double distToSeg(Offset p, Offset a, Offset b) =>
    (p - closestOnSeg(p, a, b)).distance;

/// Solves p + t*r = q + u*s. Returns [t, u] or null if parallel.
List<double>? segParams(Offset p, Offset r, Offset q, Offset s) {
  final rxs = r.dx * s.dy - r.dy * s.dx;
  if (rxs.abs() < 1e-9) return null;
  final qp = q - p;
  final t = (qp.dx * s.dy - qp.dy * s.dx) / rxs;
  final u = (qp.dx * r.dy - qp.dy * r.dx) / rxs;
  return [t, u];
}

Offset rotAbout(Offset p, Offset c, double rad) {
  final dx = p.dx - c.dx, dy = p.dy - c.dy;
  return Offset(c.dx + dx * cos(rad) - dy * sin(rad),
      c.dy + dx * sin(rad) + dy * cos(rad));
}

double polyArea(List<Offset> p) {
  double a = 0;
  for (int i = 0; i < p.length; i++) {
    final q = p[(i + 1) % p.length];
    a += p[i].dx * q.dy - q.dx * p[i].dy;
  }
  return a / 2;
}

Offset polyCentroid(List<Offset> p) {
  double a = 0, cx = 0, cy = 0;
  for (int i = 0; i < p.length; i++) {
    final q = p[(i + 1) % p.length];
    final cr = p[i].dx * q.dy - q.dx * p[i].dy;
    a += cr;
    cx += (p[i].dx + q.dx) * cr;
    cy += (p[i].dy + q.dy) * cr;
  }
  a /= 2;
  if (a.abs() < 1e-6) return p.first;
  return Offset(cx / (6 * a), cy / (6 * a));
}

bool pointInPoly(Offset p, List<Offset> poly) {
  var inside = false;
  for (int i = 0, j = poly.length - 1; i < poly.length; j = i++) {
    final a = poly[i], b = poly[j];
    if ((a.dy > p.dy) != (b.dy > p.dy) &&
        p.dx < (b.dx - a.dx) * (p.dy - a.dy) / (b.dy - a.dy) + a.dx) {
      inside = !inside;
    }
  }
  return inside;
}

Offset insidePoint(List<Offset> poly) {
  final c = polyCentroid(poly);
  if (pointInPoly(c, poly)) return c;
  double x0 = poly.first.dx, x1 = x0, y0 = poly.first.dy, y1 = y0;
  for (final p in poly) {
    x0 = min(x0, p.dx);
    x1 = max(x1, p.dx);
    y0 = min(y0, p.dy);
    y1 = max(y1, p.dy);
  }
  Offset? best;
  double bd = double.infinity;
  for (int i = 1; i < 20; i++) {
    for (int j = 1; j < 20; j++) {
      final q = Offset(x0 + (x1 - x0) * i / 20, y0 + (y1 - y0) * j / 20);
      if (pointInPoly(q, poly) && (q - c).distance < bd) {
        bd = (q - c).distance;
        best = q;
      }
    }
  }
  return best ?? c;
}

List<Offset> hull(List<Offset> pts) {
  final p = [...pts]..sort((a, b) =>
      a.dx != b.dx ? a.dx.compareTo(b.dx) : a.dy.compareTo(b.dy));
  if (p.length < 3) return p;
  double cross(Offset o, Offset a, Offset b) =>
      (a.dx - o.dx) * (b.dy - o.dy) - (a.dy - o.dy) * (b.dx - o.dx);
  final lo = <Offset>[];
  for (final q in p) {
    while (lo.length >= 2 && cross(lo[lo.length - 2], lo.last, q) <= 0) {
      lo.removeLast();
    }
    lo.add(q);
  }
  final up = <Offset>[];
  for (final q in p.reversed) {
    while (up.length >= 2 && cross(up[up.length - 2], up.last, q) <= 0) {
      up.removeLast();
    }
    up.add(q);
  }
  lo.removeLast();
  up.removeLast();
  return [...lo, ...up];
}

double wallExt(Wall w, Offset p, List<Wall> all) {
  double e = 0;
  for (final o in all) {
    if (identical(o, w)) continue;
    if (distToSeg(p, o.a, o.b) < 1.0) e = max(e, o.t / 2);
  }
  return e;
}

List<Offset> wallPoly(Wall w, List<Wall> all) {
  final u = w.dir;
  final n = w.normal * (w.t / 2);
  final a = w.a - u * wallExt(w, w.a, all);
  final b = w.b + u * wallExt(w, w.b, all);
  return [a + n, b + n, b - n, a - n];
}

List<Offset> furnPoly(Furn f) {
  final r = f.rot * pi / 180;
  final hw = f.w / 2, hd = f.d / 2;
  return [
    Offset(-hw, -hd), Offset(hw, -hd), Offset(hw, hd), Offset(-hw, hd)
  ]
      .map((p) => f.c +
          Offset(p.dx * cos(r) - p.dy * sin(r), p.dx * sin(r) + p.dy * cos(r)))
      .toList();
}

List<Offset> pillarPoly(Pillar p) {
  if (p.round) {
    return [
      for (int i = 0; i < 16; i++)
        p.c +
            Offset(cos(i * pi / 8) * p.w / 2, sin(i * pi / 8) * p.d / 2)
    ];
  }
  final hw = p.w / 2, hd = p.d / 2;
  return [
    p.c + Offset(-hw, -hd), p.c + Offset(hw, -hd),
    p.c + Offset(hw, hd), p.c + Offset(-hw, hd)
  ];
}

List<Offset> dimLine(Dim d, Doc doc) {
  if (d.wallId != null) {
    final w = doc.wall(d.wallId!);
    if (w != null) return [w.a, w.b];
  }
  return [d.a, d.b];
}

class RoomInfo {
  final List<Offset> poly;
  final double area, perim, net, tavg, iw, ih;
  final bool ortho, isRect, netApprox;
  final Offset center;
  final RoomTag? tag;
  String name;
  int index;
  RoomInfo({
    required this.poly, required this.area, required this.perim,
    required this.net, required this.tavg, required this.iw,
    required this.ih, required this.ortho, required this.isRect,
    required this.netApprox, required this.center, required this.tag,
    required this.name, required this.index,
  });
}

List<RoomInfo> detectRooms(Doc doc) {
  final walls = doc.objs.whereType<Wall>().where((w) => w.len > 1.0).toList();
  if (walls.length < 3) return [];
  final nodes = <String, Offset>{};
  final adj = <String, Set<String>>{};
  String nk(Offset p) {
    for (final e in nodes.entries) {
      if ((e.value - p).distance < 1.0) return e.key;
    }
    final key = 'n${nodes.length}';
    nodes[key] = p;
    return key;
  }

  void edge(Offset a, Offset b) {
    final ka = nk(a), kb = nk(b);
    if (ka == kb) return;
    adj.putIfAbsent(ka, () => <String>{}).add(kb);
    adj.putIfAbsent(kb, () => <String>{}).add(ka);
  }

  for (final w in walls) {
    final r = w.b - w.a;
    final L = w.len;
    final ts = <double>[0.0, 1.0];
    for (final o in walls) {
      if (identical(o, w)) continue;
      for (final pt in [o.a, o.b]) {
        final cp = closestOnSeg(pt, w.a, w.b);
        if ((cp - pt).distance < 1.0) ts.add((cp - w.a).distance / L);
      }
      final x = segParams(w.a, r, o.a, o.b - o.a);
      if (x != null && x[0] > 0 && x[0] < 1 && x[1] > 0 && x[1] < 1) {
        ts.add(x[0]);
      }
    }
    ts.sort();
    for (int i = 0; i + 1 < ts.length; i++) {
      edge(w.a + r * ts[i], w.a + r * ts[i + 1]);
    }
  }
  var changed = true;
  while (changed) {
    changed = false;
    for (final key in adj.keys.toList()) {
      final s = adj[key];
      if (s == null) continue;
      if (s.length < 2) {
        for (final n in s) {
          adj[n]?.remove(key);
        }
        adj.remove(key);
        changed = true;
      }
    }
  }
  final order = <String, List<String>>{};
  adj.forEach((key, s) {
    final p = nodes[key]!;
    final l = s.toList();
    l.sort((x, y) {
      final ax = atan2(nodes[x]!.dy - p.dy, nodes[x]!.dx - p.dx);
      final ay = atan2(nodes[y]!.dy - p.dy, nodes[y]!.dx - p.dx);
      return ax.compareTo(ay);
    });
    order[key] = l;
  });
  final used = <String>{};
  final res = <RoomInfo>[];
  for (final u in order.keys) {
    for (final v in order[u]!) {
      if (used.contains('$u>$v')) continue;
      final cyc = <String>[];
      var cu = u, cv = v;
      var guard = 0;
      while (!used.contains('$cu>$cv') && guard++ < 600) {
        used.add('$cu>$cv');
        cyc.add(cu);
        final l = order[cv]!;
        final i = l.indexOf(cu);
        final nx = l[(i - 1 + l.length) % l.length];
        cu = cv;
        cv = nx;
      }
      if (cyc.length < 3) continue;
      final poly = [for (final id in cyc) nodes[id]!];
      final area = polyArea(poly);
      if (area < 2e5) continue;
      double perim = 0, tsum = 0;
      for (int i = 0; i < poly.length; i++) {
        final p = poly[i], q = poly[(i + 1) % poly.length];
        perim += (q - p).distance;
        final m = (p + q) / 2;
        double bd = double.infinity;
        double bt = 230;
        for (final w in walls) {
          final d = distToSeg(m, w.a, w.b);
          if (d < bd) {
            bd = d;
            bt = w.t;
          }
        }
        tsum += bt;
      }
      final tavg = tsum / poly.length;
      // simplify (remove collinear vertices)
      final sp = <Offset>[];
      for (int i = 0; i < poly.length; i++) {
        final a = poly[(i - 1 + poly.length) % poly.length];
        final b = poly[i];
        final c = poly[(i + 1) % poly.length];
        final v1 = b - a, v2 = c - b;
        final l1 = v1.distance, l2 = v2.distance;
        if (l1 < 1e-6 || l2 < 1e-6) continue;
        final cr = (v1.dx * v2.dy - v1.dy * v2.dx) / (l1 * l2);
        if (cr.abs() > 1e-3) sp.add(b);
      }
      var ortho = sp.length >= 4;
      for (int i = 0; i < sp.length && ortho; i++) {
        final a = sp[(i - 1 + sp.length) % sp.length];
        final b = sp[i];
        final c = sp[(i + 1) % sp.length];
        final v1 = b - a, v2 = c - b;
        final dot = (v1.dx * v2.dx + v1.dy * v2.dy) / (v1.distance * v2.distance);
        if (dot.abs() > 0.02) ortho = false;
      }
      final isRect = ortho && sp.length == 4;
      double x0 = poly.first.dx, x1 = x0, y0 = poly.first.dy, y1 = y0;
      for (final p in poly) {
        x0 = min(x0, p.dx);
        x1 = max(x1, p.dx);
        y0 = min(y0, p.dy);
        y1 = max(y1, p.dy);
      }
      var varied = false;
      for (final w in walls) {
        if ((w.t - tavg).abs() > 1) varied = true;
      }
      final net = ortho ? area - perim * tavg / 2 + tavg * tavg : double.nan;
      final center = insidePoint(poly);
      RoomTag? tag;
      for (final t in doc.tags) {
        if (pointInPoly(t.pos, poly)) {
          tag = t;
          break;
        }
      }
      res.add(RoomInfo(
        poly: poly, area: area, perim: perim, net: net, tavg: tavg,
        iw: isRect ? (x1 - x0) - tavg : double.nan,
        ih: isRect ? (y1 - y0) - tavg : double.nan,
        ortho: ortho, isRect: isRect, netApprox: varied, center: center,
        tag: tag, name: tag?.name ?? 'ROOM', index: 0,
      ));
    }
  }
  res.sort((a, b) => a.center.dy != b.center.dy
      ? a.center.dy.compareTo(b.center.dy)
      : a.center.dx.compareTo(b.center.dx));
  for (int i = 0; i < res.length; i++) {
    res[i].index = i + 1;
    if (res[i].tag == null) res[i].name = 'ROOM ${i + 1}';
  }
  return res;
}
