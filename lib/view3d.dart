import 'dart:math';
import 'package:flutter/material.dart';
import 'model.dart';
import 'geo.dart';

class V3 {
  final double x, y, z;
  const V3(this.x, this.y, this.z);
}

class Face3 {
  final List<V3> pts;
  final Color color;
  final V3 n;
  final double alpha;
  Face3(this.pts, this.color, this.n, this.alpha);
}

class Caster {
  final List<Offset> poly;
  final double h;
  Caster(this.poly, this.h);
}

class Scene3 {
  final floors = <Face3>[];
  final solids = <Face3>[];
  final casters = <Caster>[];
  V3 center = const V3(0, 0, 0);
  double extent = 1;
}

V3 _v(Offset p, double z) => V3(p.dx, -p.dy, z);

void _prism(Scene3 s, List<Offset> poly, double z0, double z1, Color col,
    {double alpha = 1, bool casts = true}) {
  if (poly.length < 3 || z1 - z0 < 1) return;
  double cx = 0, cy = 0;
  for (final p in poly) {
    cx += p.dx;
    cy += p.dy;
  }
  cx /= poly.length;
  cy /= poly.length;
  s.solids.add(Face3([for (final p in poly) _v(p, z1)], col, const V3(0, 0, 1), alpha));
  for (int i = 0; i < poly.length; i++) {
    final p = poly[i], q = poly[(i + 1) % poly.length];
    final e = q - p;
    var nx = e.dy, ny = -e.dx;
    final mx = (p.dx + q.dx) / 2 - cx, my = (p.dy + q.dy) / 2 - cy;
    if (nx * mx + ny * my < 0) {
      nx = -nx;
      ny = -ny;
    }
    final l = sqrt(nx * nx + ny * ny);
    if (l < 1e-9) continue;
    s.solids.add(Face3([_v(p, z0), _v(q, z0), _v(q, z1), _v(p, z1)], col,
        V3(nx / l, -ny / l, 0), alpha));
  }
  if (casts) s.casters.add(Caster(poly, z1));
}

Scene3 buildScene(Doc doc, List<RoomInfo> rooms) {
  final s = Scene3();
  final lay = {for (final l in doc.layers) l.name: l};
  bool on(Obj o) => lay[o.layer]?.visible ?? true;
  final walls = doc.objs.whereType<Wall>().where(on).toList();
  final ops = doc.objs.whereType<Opening>().where(on).toList();
  for (final r in rooms) {
    s.floors.add(Face3([for (final p in r.poly) V3(p.dx, -p.dy, 0)],
        matColor(r.tag?.floor ?? 'Concrete'), const V3(0, 0, 1), 1));
  }
  for (final w in walls) {
    final u = w.dir;
    final n = w.normal * (w.t / 2);
    final ea = wallExt(w, w.a, walls), eb = wallExt(w, w.b, walls);
    final L = w.len;
    final col = matColor(w.mat);
    List<Offset> rect(double s0, double s1, [double k = 1]) {
      final a = w.a + u * s0, b = w.a + u * s1;
      final nn = n * k;
      return [a + nn, b + nn, b - nn, a - nn];
    }

    final mine = ops.where((o) => o.wallId == w.id).toList()
      ..sort((x, y) => x.pos.compareTo(y.pos));
    double cur = -ea;
    for (final o in mine) {
      final s0 = max(o.pos - o.w / 2, -ea), s1 = min(o.pos + o.w / 2, L + eb);
      if (s0 > cur) _prism(s, rect(cur, s0), 0, w.h, col);
      final top = o.sill + o.h;
      if (top < w.h) _prism(s, rect(s0, s1), top, w.h, col);
      if (o.sill > 0) _prism(s, rect(s0, s1), 0, o.sill, col);
      if (o.isDoor) {
        _prism(s, rect(s0, s1, 0.18), 0, min(o.h, w.h), matColor('Wood'), casts: false);
      } else {
        _prism(s, rect(s0, s1, 0.12), o.sill, min(o.sill + o.h, w.h),
            matColor('Glass'), alpha: 0.38, casts: false);
      }
      cur = max(cur, s1);
    }
    if (cur < L + eb) _prism(s, rect(cur, L + eb), 0, w.h, col);
  }
  for (final p in doc.objs.whereType<Pillar>().where(on)) {
    _prism(s, pillarPoly(p), 0, p.h, matColor(p.mat));
  }
  for (final f in doc.objs.whereType<Furn>().where(on)) {
    _prism(s, furnPoly(f), 0, f.h, Color(f.color));
  }
  double x0 = 1e18, y0 = 1e18, z0 = 0, x1 = -1e18, y1 = -1e18, z1 = 0;
  for (final f in [...s.floors, ...s.solids]) {
    for (final p in f.pts) {
      x0 = min(x0, p.x);
      x1 = max(x1, p.x);
      y0 = min(y0, p.y);
      y1 = max(y1, p.y);
      z1 = max(z1, p.z);
    }
  }
  if (x0 > x1) {
    x0 = 0;
    x1 = 1;
    y0 = 0;
    y1 = 1;
  }
  s.center = V3((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2);
  final e = sqrt(pow(x1 - x0, 2) + pow(y1 - y0, 2) + pow(z1 - z0, 2));
  s.extent = e < 1 ? 1 : e.toDouble();
  return s;
}

class Cam3 {
  final double yaw, el, zoom, dist, base;
  final V3 target;
  final Offset pan;
  final Size size;
  final bool persp;
  Cam3(this.yaw, this.el, this.zoom, this.dist, this.target, this.pan,
      this.size, this.persp, this.base);

  List<double> project(V3 p) {
    final x = p.x - target.x, y = p.y - target.y, z = p.z - target.z;
    final cy = cos(yaw), sy = sin(yaw);
    final x1 = x * cy - y * sy, y1 = x * sy + y * cy;
    final ce = cos(el), se = sin(el);
    final up = y1 * se + z * ce;
    final depth = y1 * ce - z * se;
    var f = zoom * base;
    if (persp) {
      final dd = dist + depth;
      f *= dist / (dd < dist * 0.1 ? dist * 0.1 : dd);
    }
    return [size.width / 2 + pan.dx + x1 * f, size.height / 2 + pan.dy - up * f, depth];
  }

  double facing(V3 n) {
    final y1 = n.x * sin(yaw) + n.y * cos(yaw);
    return -y1 * cos(el) + n.z * sin(el);
  }
}

int _c8(double v) {
  final r = v.round();
  return r < 0 ? 0 : (r > 255 ? 255 : r);
}

Color _shade(Color c, double k) =>
    Color.fromARGB(255, _c8(c.r * 255 * k), _c8(c.g * 255 * k), _c8(c.b * 255 * k));

class _Proj {
  final List<Offset> pts;
  final double depth;
  final Face3 f;
  _Proj(this.pts, this.depth, this.f);
}

class Scene3Painter extends CustomPainter {
  final Scene3 sc;
  final int mode; // 0 wire, 1 shaded, 2 realistic
  final double yaw, el, zoom, sunAz, sunEl;
  final Offset pan;
  final bool persp;
  Scene3Painter(this.sc, this.mode, this.yaw, this.el, this.zoom, this.pan,
      this.persp, this.sunAz, this.sunEl);

  @override
  void paint(Canvas c, Size size) {
    c.drawRect(Offset.zero & size, Paint()..color = const Color(0xFF0B121B));
    if (sc.solids.isEmpty && sc.floors.isEmpty) {
      final tp = TextPainter(
          text: const TextSpan(
              text: 'Nothing to show. Draw some walls first.',
              style: TextStyle(color: Colors.white54, fontSize: 13)),
          textDirection: TextDirection.ltr)
        ..layout();
      tp.paint(c, Offset((size.width - tp.width) / 2, size.height / 2));
      return;
    }
    final cam = Cam3(yaw, el, zoom, sc.extent * 2.5, sc.center, pan, size,
        persp, min(size.width, size.height) * 0.8 / sc.extent);
    Offset pr(V3 p) {
      final r = cam.project(p);
      return Offset(r[0], r[1]);
    }

    for (final f in sc.floors) {
      final path = Path()..addPolygon([for (final p in f.pts) pr(p)], true);
      if (mode == 0) {
        c.drawPath(path, Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.white24);
      } else {
        c.drawPath(path, Paint()..color = mode == 2 ? f.color : const Color(0xFF2A3544));
      }
    }
    final lx = cos(sunEl) * cos(sunAz), ly = cos(sunEl) * sin(sunAz), lz = sin(sunEl);
    if (mode == 2 && lz > 0.05) {
      final path = Path();
      for (final k in sc.casters) {
        final sh = Offset(-lx / lz * k.h, ly / lz * k.h);
        final h = hull([...k.poly, ...k.poly.map((p) => p + sh)]);
        if (h.length < 3) continue;
        path.addPolygon([for (final p in h) pr(V3(p.dx, -p.dy, 0.5))], true);
      }
      c.drawPath(path, Paint()..color = const Color(0x55000000));
    }
    final list = <_Proj>[];
    for (final f in sc.solids) {
      if (mode != 0 && cam.facing(f.n) <= 0) continue;
      double d = 0;
      final pts = <Offset>[];
      for (final p in f.pts) {
        final r = cam.project(p);
        pts.add(Offset(r[0], r[1]));
        d += r[2];
      }
      list.add(_Proj(pts, d / f.pts.length, f));
    }
    list.sort((a, b) => b.depth.compareTo(a.depth));
    for (final q in list) {
      final path = Path()..addPolygon(q.pts, true);
      if (mode == 0) {
        c.drawPath(path, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = Colors.white70);
        continue;
      }
      final k = 0.40 + 0.60 * max(0.0, q.f.n.x * lx + q.f.n.y * ly + q.f.n.z * lz);
      final base = mode == 2 ? q.f.color : const Color(0xFFB8C1CC);
      c.drawPath(path, Paint()..color = _shade(base, k).withValues(alpha: q.f.alpha));
      c.drawPath(path, Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.7
        ..color = const Color(0x55000000));
    }
  }

  @override
  bool shouldRepaint(covariant Scene3Painter old) => true;
}

class View3D extends StatefulWidget {
  final Doc doc;
  final List<RoomInfo> rooms;
  final int ver;
  const View3D({super.key, required this.doc, required this.rooms, required this.ver});
  @override
  State<View3D> createState() => _View3DState();
}

class _View3DState extends State<View3D> {
  Scene3? sc;
  int _v = -1;
  double yaw = 0.8, el = 0.6, zoom = 1, sunAz = 0.9, sunEl = 0.9, _bz = 1;
  Offset pan = Offset.zero;
  bool persp = true;
  int mode = 2;

  Widget _chip(String t, bool on, VoidCallback f) => Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(t, style: const TextStyle(fontSize: 12)),
          selected: on,
          onSelected: (_) => f(),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );

  void _view(double y, double e, bool p) => setState(() {
        yaw = y;
        el = e;
        persp = p;
        pan = Offset.zero;
        zoom = 1;
      });

  @override
  Widget build(BuildContext context) {
    if (_v != widget.ver || sc == null) {
      sc = buildScene(widget.doc, widget.rooms);
      _v = widget.ver;
    }
    return Stack(children: [
      Positioned.fill(
        child: GestureDetector(
          onScaleStart: (d) => _bz = zoom,
          onScaleUpdate: (d) {
            setState(() {
              if (d.pointerCount == 1) {
                yaw += d.focalPointDelta.dx * 0.01;
                el = (el + d.focalPointDelta.dy * 0.01).clamp(0.05, 1.5707).toDouble();
              } else {
                zoom = (_bz * d.scale).clamp(0.2, 8.0).toDouble();
                pan += d.focalPointDelta;
              }
            });
          },
          child: CustomPaint(
              painter: Scene3Painter(sc!, mode, yaw, el, zoom, pan, persp, sunAz, sunEl),
              size: Size.infinite),
        ),
      ),
      Positioned(
        top: 6, left: 6, right: 120,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: [
            _chip('Wire', mode == 0, () => setState(() => mode = 0)),
            _chip('Shaded', mode == 1, () => setState(() => mode = 1)),
            _chip('Realistic', mode == 2, () => setState(() => mode = 2)),
            _chip('Top', false, () => _view(0, 1.5707, false)),
            _chip('Front', false, () => _view(0, 0.05, false)),
            _chip('Side', false, () => _view(pi / 2, 0.05, false)),
            _chip('Iso', false, () => _view(0.785, 0.615, false)),
            _chip(persp ? 'Perspective' : 'Orthographic', persp, () => setState(() => persp = !persp)),
          ]),
        ),
      ),
      Positioned(
        left: 8, right: 8, bottom: 8,
        child: Container(
          decoration: BoxDecoration(
              color: const Color(0xCC141F2E), borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            const SizedBox(width: 10),
            const Icon(Icons.wb_sunny_outlined, size: 18),
            Expanded(
                child: Slider(
                    value: sunAz.clamp(0.0, 2 * pi).toDouble(),
                    min: 0,
                    max: 2 * pi,
                    onChanged: (v) => setState(() => sunAz = v))),
            const Text('Sun', style: TextStyle(fontSize: 12)),
            const SizedBox(width: 10),
          ]),
        ),
      ),
    ]);
  }
}
