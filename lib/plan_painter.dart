import 'dart:math';
import 'package:flutter/material.dart';
import 'model.dart';
import 'geo.dart';

class SnapRes {
  final Offset p;
  final String kind;
  const SnapRes(this.p, this.kind);
}

class PlanPainter extends CustomPainter {
  final Doc doc;
  final List<RoomInfo> rooms;
  final double s;
  final Offset o;
  final Set<String> sel;
  final Offset? selRoomPt, wallStart, draftEnd, dimA, measA, measB;
  final SnapRes? snap;
  final bool showGrid, autoDims, roomLabels;
  final double wallT;

  static const bg = Color(0xFF0D1520);

  PlanPainter({
    required this.doc, required this.rooms, required this.s, required this.o,
    required this.sel, required this.selRoomPt, required this.wallStart,
    required this.draftEnd, required this.dimA, required this.measA,
    required this.measB, required this.snap, required this.showGrid,
    required this.autoDims, required this.roomLabels, required this.wallT,
  });

  Offset sp(Offset w) => Offset(w.dx * s + o.dx, w.dy * s + o.dy);
  Path pp(List<Offset> l) => Path()..addPolygon(l, true);

  void _txt(Canvas c, String t, Offset at,
      {double size = 11, Color color = Colors.white, double angle = 0,
      bool bold = false, Color? back}) {
    final tp = TextPainter(
      text: TextSpan(
          text: t,
          style: TextStyle(
              fontSize: size,
              color: color,
              fontWeight: bold ? FontWeight.w700 : FontWeight.w500)),
      textDirection: TextDirection.ltr,
    )..layout();
    var a = angle;
    if (a > pi / 2) a -= pi;
    if (a < -pi / 2) a += pi;
    c.save();
    c.translate(at.dx, at.dy);
    c.rotate(a);
    if (back != null) {
      c.drawRect(
          Rect.fromCenter(
              center: Offset.zero, width: tp.width + 6, height: tp.height + 2),
          Paint()..color = back);
    }
    tp.paint(c, Offset(-tp.width / 2, -tp.height / 2));
    c.restore();
  }

  void _grid(Canvas c, Size size) {
    double step = doc.grid;
    while (step * s < 8) {
      step *= 5;
    }
    final minor = Paint()
      ..color = const Color(0xFF172536)
      ..strokeWidth = 1;
    final major = Paint()
      ..color = const Color(0xFF223850)
      ..strokeWidth = 1;
    final i0 = (-o.dx / s / step).floor(), i1 = ((size.width - o.dx) / s / step).ceil();
    for (int i = i0; i <= i1; i++) {
      final x = i * step * s + o.dx;
      c.drawLine(Offset(x, 0), Offset(x, size.height), i % 5 == 0 ? major : minor);
    }
    final j0 = (-o.dy / s / step).floor(), j1 = ((size.height - o.dy) / s / step).ceil();
    for (int j = j0; j <= j1; j++) {
      final y = j * step * s + o.dy;
      c.drawLine(Offset(0, y), Offset(size.width, y), j % 5 == 0 ? major : minor);
    }
    final ax = Paint()
      ..color = const Color(0x55FF5252)
      ..strokeWidth = 1;
    c.drawLine(Offset(0, o.dy), Offset(size.width, o.dy), ax);
    c.drawLine(Offset(o.dx, 0), Offset(o.dx, size.height), ax..color = const Color(0x5552FF7A));
  }

  void _swing(Canvas c, Offset hinge, Offset free, Offset nn, double r, Paint p) {
    c.drawLine(sp(hinge), sp(hinge + nn * r), p);
    final v1 = free - hinge;
    final a1 = atan2(v1.dy, v1.dx), a2 = atan2(nn.dy, nn.dx);
    var sw = a2 - a1;
    while (sw > pi) {
      sw -= 2 * pi;
    }
    while (sw < -pi) {
      sw += 2 * pi;
    }
    c.drawArc(
        Rect.fromCircle(center: sp(hinge), radius: r * s),
        a1,
        sw,
        false,
        Paint()
          ..color = p.color.withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1);
  }

  void _dim(Canvas c, Offset a, Offset b, double off, Color col, String text,
      bool selected) {
    final d = b - a;
    final L = d.distance;
    if (L < 1) return;
    final u = d / L;
    final n = Offset(-u.dy, u.dx);
    final sg = off >= 0 ? 1.0 : -1.0;
    final p1 = a + n * off, p2 = b + n * off;
    final pt = Paint()
      ..color = selected ? const Color(0xFFFFC107) : col
      ..strokeWidth = 1.2;
    c.drawLine(sp(a + n * (80 * sg)), sp(p1 + n * (120 * sg)), pt);
    c.drawLine(sp(b + n * (80 * sg)), sp(p2 + n * (120 * sg)), pt);
    c.drawLine(sp(p1), sp(p2), pt);
    final tk = Offset(u.dx + n.dx, u.dy + n.dy);
    final tv = tk / tk.distance * 5;
    for (final p in [p1, p2]) {
      c.drawLine(sp(p) - tv, sp(p) + tv, pt..strokeWidth = 1.8);
    }
    _txt(c, text, sp((p1 + p2) / 2) + Offset(n.dx, n.dy) * (9.0 * sg),
        size: 10, color: pt.color, angle: atan2(u.dy, u.dx));
  }

  @override
  void paint(Canvas c, Size size) {
    c.drawRect(Offset.zero & size, Paint()..color = bg);
    c.save();
    c.clipRect(Offset.zero & size);
    if (showGrid) _grid(c, size);
    final lay = {for (final l in doc.layers) l.name: l};
    bool on(Obj ob) => lay[ob.layer]?.visible ?? true;
    Color lc(Obj ob) => lay[ob.layer]?.color ?? Colors.white;
    final walls = doc.objs.whereType<Wall>().where(on).toList();
    final u = doc.unit, pc = doc.prec;

    for (final r in rooms) {
      final isSel = selRoomPt != null && pointInPoly(selRoomPt!, r.poly);
      c.drawPath(
          pp(r.poly.map(sp).toList()),
          Paint()
            ..color = (isSel ? const Color(0xFFFFC107) : const Color(0xFF2F9BFF))
                .withValues(alpha: isSel ? 0.22 : 0.08));
    }

    final polys = <Wall, List<Offset>>{};
    for (final w in walls) {
      polys[w] = wallPoly(w, walls).map(sp).toList();
    }
    for (final w in walls) {
      c.drawPath(
          pp(polys[w]!),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3
            ..strokeJoin = StrokeJoin.miter
            ..color = lc(w));
    }
    for (final w in walls) {
      c.drawPath(pp(polys[w]!),
          Paint()..color = Color.lerp(bg, lc(w), w.bearing ? 0.55 : 0.30)!);
    }

    for (final op in doc.objs.whereType<Opening>()) {
      if (!on(op)) continue;
      final w = doc.wall(op.wallId);
      if (w == null || !on(w)) continue;
      final uu = w.dir, n = w.normal;
      final cc = w.a + uu * op.pos;
      final hw = op.w / 2;
      final half = w.t / 2 + 3 / s;
      c.drawPath(
          pp([
            for (final p in [
              cc - uu * hw + n * half, cc + uu * hw + n * half,
              cc + uu * hw - n * half, cc - uu * hw - n * half
            ])
              sp(p)
          ]),
          Paint()..color = bg);
      final line = Paint()
        ..color = lc(op)
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke;
      for (final sg in [-1.0, 1.0]) {
        c.drawLine(sp(cc + uu * hw * sg + n * (w.t / 2)),
            sp(cc + uu * hw * sg - n * (w.t / 2)), line);
      }
      if (op.isDoor) {
        final nn = n * (op.inward ? 1.0 : -1.0);
        if (op.style == 'sliding') {
          c.drawLine(sp(cc - uu * hw + n * (w.t / 6)), sp(cc + n * (w.t / 6)), line);
          c.drawLine(sp(cc - n * (w.t / 6)), sp(cc + uu * hw - n * (w.t / 6)), line);
        } else if (op.style == 'double') {
          for (final sg in [-1.0, 1.0]) {
            _swing(c, cc + uu * hw * sg, cc, nn, hw, line);
          }
        } else {
          final hinge = op.flip ? cc + uu * hw : cc - uu * hw;
          final free = op.flip ? cc - uu * hw : cc + uu * hw;
          _swing(c, hinge, free, nn, op.w, line);
        }
      } else {
        final h2 = w.t / 2;
        c.drawLine(sp(cc - uu * hw + n * h2), sp(cc + uu * hw + n * h2), line);
        c.drawLine(sp(cc - uu * hw - n * h2), sp(cc + uu * hw - n * h2), line);
        if (op.style == 'sliding') {
          c.drawLine(sp(cc - uu * hw + n * (h2 / 3)), sp(cc + n * (h2 / 3)), line);
          c.drawLine(sp(cc - n * (h2 / 3)), sp(cc + uu * hw - n * (h2 / 3)), line);
        } else {
          c.drawLine(sp(cc - uu * hw), sp(cc + uu * hw), line);
        }
      }
    }

    var ci = 0;
    for (final p in doc.objs.whereType<Pillar>()) {
      ci++;
      if (!on(p)) continue;
      final pl = pillarPoly(p).map(sp).toList();
      c.drawPath(pp(pl), Paint()..color = lc(p).withValues(alpha: 0.85));
      c.drawPath(
          pp(pl),
          Paint()
            ..style = PaintingStyle.stroke
            ..color = Colors.white
            ..strokeWidth = 1);
      if (p.w * s > 14) {
        _txt(c, 'C$ci', sp(p.c + Offset(p.w / 2 + 120, -p.d / 2 - 100)),
            size: 9, color: lc(p));
      }
    }

    for (final f in doc.objs.whereType<Furn>()) {
      if (!on(f)) continue;
      final pl = furnPoly(f).map(sp).toList();
      c.drawPath(pp(pl), Paint()..color = lc(f).withValues(alpha: 0.22));
      c.drawPath(
          pp(pl),
          Paint()
            ..style = PaintingStyle.stroke
            ..color = lc(f)
            ..strokeWidth = 1.2);
      if (min(f.w, f.d) * s > 26) {
        _txt(c, f.kind, sp(f.c), size: 9, color: lc(f));
      }
    }

    for (final d in doc.objs.whereType<Dim>()) {
      if (!on(d)) continue;
      final l = dimLine(d, doc);
      _dim(c, l[0], l[1], d.off, lc(d), fmtLen((l[1] - l[0]).distance, u, pc),
          sel.contains(d.id));
    }

    if (autoDims) {
      for (final w in walls) {
        if (w.len * s < 50) continue;
        final n = w.normal;
        _txt(c, fmtLen(w.len, u, pc),
            sp(w.mid) + Offset(n.dx, n.dy) * -(w.t * s / 2 + 8),
            size: 9, color: const Color(0xFF69F0AE), angle: atan2(w.dir.dy, w.dir.dx));
      }
    }

    if (roomLabels) {
      for (final r in rooms) {
        final tag = r.tag;
        double x0 = double.infinity, x1 = -double.infinity;
        double y0 = double.infinity, y1 = -double.infinity;
        for (final p in r.poly) {
          final q = sp(p);
          x0 = min(x0, q.dx);
          x1 = max(x1, q.dx);
          y0 = min(y0, q.dy);
          y1 = max(y1, q.dy);
        }
        final m = min(x1 - x0, y1 - y0);
        if (m < 34) continue;
        final cp = sp(r.center);
        var y = cp.dy - (m > 70 ? 14 : 0);
        _txt(c, r.name, Offset(cp.dx, y), size: 11, bold: true);
        if ((tag?.showArea ?? true) && m > 52) {
          y += 14;
          final txt = r.net.isNaN
              ? 'Gross ${fmtArea(r.area, u)}'
              : 'Net ${fmtArea(r.net, u)}${r.netApprox ? '≈' : ''}';
          _txt(c, txt, Offset(cp.dx, y), size: 10, color: Colors.white70);
        }
        if ((tag?.showDims ?? true) && r.isRect && m > 70) {
          y += 13;
          _txt(c, '${fmtLen(r.iw, u, pc)} × ${fmtLen(r.ih, u, pc)}',
              Offset(cp.dx, y), size: 9, color: Colors.white54);
        }
      }
    }

    const amber = Color(0xFFFFC107);
    for (final id in sel) {
      final ob = doc.byId(id);
      if (ob == null) continue;
      final hp = Paint()
        ..style = PaintingStyle.stroke
        ..color = amber
        ..strokeWidth = 2.2;
      if (ob is Wall && polys[ob] != null) {
        c.drawPath(pp(polys[ob]!), hp);
        for (final p in [ob.a, ob.b]) {
          final q = sp(p);
          final r = Rect.fromCenter(center: q, width: 12, height: 12);
          c.drawRect(r, Paint()..color = Colors.white);
          c.drawRect(r, hp..strokeWidth = 1.5);
        }
      } else if (ob is Pillar) {
        c.drawPath(pp(pillarPoly(ob).map(sp).toList()), hp);
      } else if (ob is Furn) {
        c.drawPath(pp(furnPoly(ob).map(sp).toList()), hp);
      } else if (ob is Opening) {
        final w = doc.wall(ob.wallId);
        if (w != null) {
          final cc = w.a + w.dir * ob.pos;
          final hw = ob.w / 2, n = w.normal * (w.t / 2 + 40);
          c.drawPath(
              pp([
                for (final p in [
                  cc - w.dir * hw + n, cc + w.dir * hw + n,
                  cc + w.dir * hw - n, cc - w.dir * hw - n
                ])
                  sp(p)
              ]),
              hp);
        }
      }
    }

    if (wallStart != null && draftEnd != null && (draftEnd! - wallStart!).distance > 1) {
      final tw = Wall('d', 'Walls', wallStart!, draftEnd!, t: wallT);
      final pl = wallPoly(tw, const []).map(sp).toList();
      c.drawPath(pp(pl), Paint()..color = const Color(0x552F9BFF));
      c.drawPath(
          pp(pl),
          Paint()
            ..style = PaintingStyle.stroke
            ..color = const Color(0xFF2F9BFF)
            ..strokeWidth = 1.5);
      final v = draftEnd! - wallStart!;
      final ang = (-atan2(v.dy, v.dx) * 180 / pi);
      _txt(c, '${fmtLen(v.distance, u, pc)}  ∠${ang.toStringAsFixed(1)}°',
          sp((wallStart! + draftEnd!) / 2) + const Offset(0, -16),
          size: 11, bold: true, back: const Color(0xCC0D1520));
    }
    if (wallStart != null) {
      c.drawCircle(
          sp(wallStart!),
          7,
          Paint()
            ..style = PaintingStyle.stroke
            ..color = const Color(0xFF2F9BFF)
            ..strokeWidth = 2);
    }
    if (dimA != null) {
      c.drawCircle(sp(dimA!), 6, Paint()..color = const Color(0xFF69F0AE));
    }
    if (measA != null) {
      final mp = Paint()
        ..color = const Color(0xFFFFEE58)
        ..strokeWidth = 1.5;
      c.drawCircle(sp(measA!), 5, mp);
      if (measB != null) {
        c.drawLine(sp(measA!), sp(measB!), mp);
        c.drawCircle(sp(measB!), 5, mp);
        final v = measB! - measA!;
        _txt(c, '${fmtLen(v.distance, u, pc)}  ∠${(-atan2(v.dy, v.dx) * 180 / pi).toStringAsFixed(1)}°',
            sp((measA! + measB!) / 2) + const Offset(0, -14),
            size: 11, bold: true, color: const Color(0xFFFFEE58), back: const Color(0xCC0D1520));
      }
    }
    if (snap != null && snap!.kind != 'free') {
      final q = sp(snap!.p);
      final mk = Paint()
        ..style = PaintingStyle.stroke
        ..color = const Color(0xFF00E5FF)
        ..strokeWidth = 2;
      switch (snap!.kind) {
        case 'end':
          c.drawRect(Rect.fromCenter(center: q, width: 12, height: 12), mk);
          break;
        case 'mid':
          c.drawPath(
              Path()
                ..moveTo(q.dx, q.dy - 7)
                ..lineTo(q.dx + 7, q.dy + 6)
                ..lineTo(q.dx - 7, q.dy + 6)
                ..close(),
              mk);
          break;
        case 'int':
          c.drawLine(q + const Offset(-6, -6), q + const Offset(6, 6), mk);
          c.drawLine(q + const Offset(-6, 6), q + const Offset(6, -6), mk);
          break;
        case 'ctr':
          c.drawCircle(q, 7, mk);
          break;
        default:
          c.drawCircle(q, 3, mk);
      }
    }
    c.restore();
  }

  @override
  bool shouldRepaint(covariant PlanPainter old) => true;
}
