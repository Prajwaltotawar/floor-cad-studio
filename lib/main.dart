import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'model.dart';
import 'geo.dart';
import 'plan_painter.dart';
import 'view3d.dart';

void main() => runApp(const CadApp());

const kPanel = Color(0xFF141F2E);
const kAccent = Color(0xFF2F9BFF);
const kAmber = Color(0xFFFFC107);

enum Tool { select, pan, wall, door, window, column, dim, measure, extend }

const kToolLabel = {
  Tool.select: 'Select',
  Tool.pan: 'Pan',
  Tool.wall: 'Wall',
  Tool.door: 'Door',
  Tool.window: 'Window',
  Tool.column: 'Column',
  Tool.dim: 'Dimension',
  Tool.measure: 'Measure',
  Tool.extend: 'Extend',
};

const kToolIcon = {
  Tool.select: Icons.near_me,
  Tool.pan: Icons.pan_tool_outlined,
  Tool.wall: Icons.vertical_split,
  Tool.door: Icons.door_front_door_outlined,
  Tool.window: Icons.window_outlined,
  Tool.column: Icons.crop_square,
  Tool.dim: Icons.height,
  Tool.measure: Icons.straighten,
  Tool.extend: Icons.keyboard_tab,
};

class Cmd {
  final String name, desc;
  final Future<void> Function() run;
  Cmd(this.name, this.desc, this.run);
}

class FurnDef {
  final String name;
  final double w, d, h;
  final int color;
  const FurnDef(this.name, this.w, this.d, this.h, this.color);
}

const kFurn = [
  FurnDef('Double bed', 1800, 2000, 500, 0xFF8E7CC3),
  FurnDef('Single bed', 1000, 2000, 500, 0xFF8E7CC3),
  FurnDef('Sofa', 2100, 900, 800, 0xFFBA68C8),
  FurnDef('Dining table', 1600, 900, 750, 0xFFA1887F),
  FurnDef('Chair', 450, 450, 900, 0xFFA1887F),
  FurnDef('Wardrobe', 1800, 600, 2100, 0xFF9E9E9E),
  FurnDef('Kitchen counter', 3000, 600, 900, 0xFF90A4AE),
  FurnDef('Refrigerator', 700, 700, 1800, 0xFFB0BEC5),
  FurnDef('Sink', 600, 500, 900, 0xFF80DEEA),
  FurnDef('Toilet', 400, 700, 800, 0xFFE0E0E0),
  FurnDef('Shower', 900, 900, 2000, 0xFF81D4FA),
  FurnDef('Bathtub', 1700, 750, 550, 0xFFE0E0E0),
  FurnDef('Washbasin', 550, 450, 850, 0xFFE0E0E0),
  FurnDef('TV unit', 1500, 400, 500, 0xFF8D6E63),
];

class CadApp extends StatelessWidget {
  const CadApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'CAD Floor Studio',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          brightness: Brightness.dark,
          useMaterial3: true,
          colorScheme:
              ColorScheme.fromSeed(seedColor: kAccent, brightness: Brightness.dark),
          scaffoldBackgroundColor: const Color(0xFF0B121B),
        ),
        home: const Studio(),
      );
}

class Studio extends StatefulWidget {
  const Studio({super.key});
  @override
  State<Studio> createState() => _StudioState();
}

class _StudioState extends State<Studio> {
  Doc doc = Doc();
  List<RoomInfo> rooms = [];
  int ver = 0;
  double scale = 0.08;
  Offset origin = const Offset(40, 90);
  Size cv = const Size(400, 600);

  Tool tool = Tool.select;
  Set<String> sel = {};
  Offset? selRoomPt;
  bool multi = false, view3d = false;
  bool snapGrid = true, snapObj = true, ortho = false;
  bool showGrid = true, autoDims = false, roomLabels = true;
  double wallT = 230, wallH = 3000;
  Offset? wallStart, draftEnd, dimA, measA, measB, cursor;
  SnapRes? snapMark;
  String? extId;
  Offset? extTap;
  final List<String> undoS = [], redoS = [];
  bool dirty = false;
  Timer? _timer;

  String _mode = '';
  Offset _sFocal = Offset.zero, _sOrigin = Offset.zero;
  Offset _dragRef = Offset.zero, _dragW0 = Offset.zero, _endCur = Offset.zero;
  double _sScale = 0.08;
  bool _endIsA = true;
  String? _slideId;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    try {
      final p = await SharedPreferences.getInstance();
      final s = p.getString('autosave');
      if (s != null) {
        final d = Doc.decode(s);
        if (!mounted) return;
        setState(() {
          doc = d;
          _refresh();
          dirty = false;
        });
        WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
        return;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _loadTemplate();
      _refresh();
      dirty = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _fit());
  }

  void _touchSave() {
    dirty = true;
    _timer?.cancel();
    _timer = Timer(const Duration(milliseconds: 900), () async {
      try {
        final p = await SharedPreferences.getInstance();
        await p.setString('autosave', doc.encode());
        if (mounted) setState(() => dirty = false);
      } catch (_) {}
    });
  }

  Future<void> _saveNamed() async {
    try {
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList('projects') ?? <String>[];
      if (!list.contains(doc.name)) list.add(doc.name);
      await p.setStringList('projects', list);
      await p.setString('proj_${doc.name}', doc.encode());
      _toast('Saved "${doc.name}"');
    } catch (e) {
      _toast('Save failed: $e');
    }
  }

  Future<void> _openProject() async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList('projects') ?? <String>[];
    if (!mounted) return;
    if (list.isEmpty) {
      _toast('No saved projects yet');
      return;
    }
    final pick = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(title: const Text('Open project'), children: [
              for (final n in list)
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, n), child: Text(n)),
            ]));
    if (pick == null) return;
    final s = p.getString('proj_$pick');
    if (s == null) return;
    _pushUndo();
    setState(() {
      doc = Doc.decode(s);
      sel = {};
      _refresh();
    });
    _fit();
    _touchSave();
  }

  Future<void> _newProject() async {
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: const Text('New project?'),
              content: const Text('Unsaved changes in the current drawing will be replaced.'),
              actions: [
                TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
                FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('New')),
              ],
            ));
    if (ok != true) return;
    _pushUndo();
    setState(() {
      doc = Doc();
      sel = {};
      selRoomPt = null;
      _refresh();
    });
    _fit();
    _touchSave();
  }

  Offset _tw(Offset s) => Offset((s.dx - origin.dx) / scale, (s.dy - origin.dy) / scale);
  Offset _ts(Offset w) => Offset(w.dx * scale + origin.dx, w.dy * scale + origin.dy);

  double get _f => unitFactor(doc.unit);
  String get _u => unitName(doc.unit);

  void _toast(String m) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(m), duration: const Duration(seconds: 2)));
  }

  void _pushUndo() {
    undoS.add(doc.encode());
    if (undoS.length > 60) undoS.removeAt(0);
    redoS.clear();
  }

  void _refresh() {
    rooms = detectRooms(doc);
    ver++;
  }

  void _commit(void Function() fn) {
    _pushUndo();
    setState(() {
      fn();
      _refresh();
    });
    _touchSave();
  }

  void _restore(String s) {
    final keep = doc;
    final d = Doc.decode(s);
    d.unit = keep.unit;
    d.prec = keep.prec;
    d.grid = keep.grid;
    d.name = keep.name;
    doc = d;
    sel = {};
    selRoomPt = null;
    _refresh();
  }

  void _undo() {
    if (undoS.isEmpty) return;
    redoS.add(doc.encode());
    final s = undoS.removeLast();
    setState(() => _restore(s));
    _touchSave();
  }

  void _redo() {
    if (redoS.isEmpty) return;
    undoS.add(doc.encode());
    final s = redoS.removeLast();
    setState(() => _restore(s));
    _touchSave();
  }

  void _fit() {
    final pts = <Offset>[];
    for (final o in doc.objs) {
      if (o is Wall) {
        pts.add(o.a);
        pts.add(o.b);
      } else if (o is Pillar) {
        pts.add(o.c);
      } else if (o is Furn) {
        pts.addAll(furnPoly(o));
      }
    }
    if (pts.isEmpty) {
      setState(() {
        scale = 0.08;
        origin = const Offset(60, 100);
      });
      return;
    }
    var x0 = pts.first.dx, x1 = x0, y0 = pts.first.dy, y1 = y0;
    for (final p in pts) {
      x0 = min(x0, p.dx);
      x1 = max(x1, p.dx);
      y0 = min(y0, p.dy);
      y1 = max(y1, p.dy);
    }
    final bw = max(x1 - x0, 1000.0), bh = max(y1 - y0, 1000.0);
    final sc = min((cv.width - 110) / bw, (cv.height - 120) / bh);
    setState(() {
      scale = max(0.004, min(sc, 1.0));
      origin = Offset(cv.width / 2 - (x0 + x1) / 2 * scale,
          cv.height / 2 - (y0 + y1) / 2 * scale);
    });
  }

  void _loadTemplate() {
    doc.objs.clear();
    doc.tags.clear();
    Wall wl(double x0, double y0, double x1, double y1, double t) {
      final w = Wall(doc.nid(), 'Walls', Offset(x0, y0), Offset(x1, y1),
          t: t, mat: t > 150 ? 'Brick' : 'Plaster');
      doc.objs.add(w);
      return w;
    }

    void op(Wall w, double pos,
        {bool door = true,
        double ww = 900,
        double h = 2100,
        double sill = 0,
        String style = 'single'}) {
      doc.objs.add(Opening(doc.nid(), door ? 'Doors' : 'Windows', w.id, pos,
          w: ww, h: h, sill: sill, isDoor: door, style: style));
    }

    final top = wl(0, 0, 9000, 0, 230);
    final right = wl(9000, 0, 9000, 11000, 230);
    final bottom = wl(9000, 11000, 0, 11000, 230);
    final left = wl(0, 11000, 0, 0, 230);
    final mid = wl(4500, 0, 4500, 11000, 115);
    final h1 = wl(0, 5500, 4500, 5500, 115);
    final h2 = wl(4500, 4000, 9000, 4000, 115);
    op(bottom, 2000, ww: 1000);
    op(mid, 2800);
    op(mid, 8300, ww: 800);
    op(h1, 2250, ww: 800);
    op(h2, 2250);
    op(top, 6750, door: false, ww: 1500, h: 1200, sill: 900, style: 'sliding');
    op(right, 7000, door: false, ww: 1500, h: 1200, sill: 900, style: 'sliding');
    op(left, 8000, door: false, ww: 1500, h: 1200, sill: 900, style: 'sliding');
    op(bottom, 5500, door: false, ww: 1500, h: 1200, sill: 900, style: 'sliding');
    for (final p in const [
      Offset(0, 0), Offset(4500, 0), Offset(9000, 0), Offset(0, 5500),
      Offset(4500, 5500), Offset(4500, 4000), Offset(9000, 4000),
      Offset(0, 11000), Offset(4500, 11000), Offset(9000, 11000)
    ]) {
      doc.objs.add(Pillar(doc.nid(), 'Columns', p, w: 300, d: 300));
    }
    doc.objs.add(Furn(doc.nid(), 'Furniture', 'Double bed',
        const Offset(2250, 2300), 1800, 2000, 500));
    doc.objs.add(Furn(doc.nid(), 'Furniture', 'Sofa',
        const Offset(6750, 8500), 2100, 900, 800, color: 0xFFBA68C8));
    doc.objs.add(Furn(doc.nid(), 'Furniture', 'Kitchen counter',
        const Offset(6750, 450), 3000, 600, 900, color: 0xFF90A4AE));
    doc.tags.addAll([
      RoomTag(const Offset(2250, 3200), 'BEDROOM'),
      RoomTag(const Offset(2250, 8500), 'BEDROOM 2'),
      RoomTag(const Offset(6750, 2000), 'KITCHEN'),
      RoomTag(const Offset(6750, 7000), 'LIVING', floor: 'Marble'),
    ]);
  }
  bool _visible(Obj o) => doc.layerOf(o.layer)?.visible ?? true;

  SnapRes _snap(Offset w, {Offset? from, Set<String>? ex}) {
    final tol = 16 / scale;
    if (snapObj) {
      SnapRes? best;
      var bd = tol;
      void tryP(Offset p, String kind, double bias) {
        final d = (p - w).distance + bias;
        if (d < bd) {
          bd = d;
          best = SnapRes(p, kind);
        }
      }

      final ws = <Wall>[];
      for (final o in doc.objs) {
        if (o is Wall && _visible(o) && !(ex?.contains(o.id) ?? false)) ws.add(o);
      }
      for (final x in ws) {
        tryP(x.a, 'end', 0);
        tryP(x.b, 'end', 0);
        tryP(x.mid, 'mid', tol * 0.25);
      }
      for (final o in doc.objs) {
        if (o is Pillar && !(ex?.contains(o.id) ?? false)) tryP(o.c, 'ctr', 0);
      }
      final near = ws.where((x) => distToSeg(w, x.a, x.b) < tol * 2).toList();
      for (int i = 0; i < near.length; i++) {
        for (int j = i + 1; j < near.length; j++) {
          final r = near[i].b - near[i].a, q = near[j].b - near[j].a;
          final x = segParams(near[i].a, r, near[j].a, q);
          if (x != null && x[0] >= 0 && x[0] <= 1 && x[1] >= 0 && x[1] <= 1) {
            tryP(near[i].a + r * x[0], 'int', tol * 0.1);
          }
        }
      }
      if (best != null) return best!;
    }
    var p = w;
    var kind = 'free';
    final g = doc.grid;
    if (from != null) {
      final v = w - from;
      final len = v.distance;
      if (len > 1e-6) {
        var ang = atan2(v.dy, v.dx);
        final step = ortho ? pi / 2 : pi / 4;
        final nr = (ang / step).round() * step;
        if (ortho || (ang - nr).abs() < 0.05) {
          ang = nr;
          kind = 'ang';
        }
        if (kind == 'ang') {
          var l = len;
          if (snapGrid) {
            l = (len / g).round() * g;
            if (l < g) l = g;
          }
          p = from + Offset(cos(ang), sin(ang)) * l;
        } else if (snapGrid) {
          p = Offset((w.dx / g).round() * g, (w.dy / g).round() * g);
          kind = 'grid';
        }
      }
    } else if (snapGrid) {
      p = Offset((w.dx / g).round() * g, (w.dy / g).round() * g);
      kind = 'grid';
    }
    return SnapRes(p, kind);
  }

  int _prio(Obj o) => o is Opening ? 0 : (o is Pillar || o is Furn) ? 1 : o is Dim ? 2 : 3;

  bool _hit(Obj o, Offset w, double tol) {
    if (o is Wall) return distToSeg(w, o.a, o.b) <= max(tol, o.t / 2);
    if (o is Opening) {
      final wl = doc.wall(o.wallId);
      if (wl == null) return false;
      final d = w - (wl.a + wl.dir * o.pos);
      final along = d.dx * wl.dir.dx + d.dy * wl.dir.dy;
      final across = d.dx * wl.normal.dx + d.dy * wl.normal.dy;
      return along.abs() <= o.w / 2 + tol && across.abs() <= wl.t / 2 + tol;
    }
    if (o is Pillar) {
      final d = w - o.c;
      return d.dx.abs() <= o.w / 2 + tol && d.dy.abs() <= o.d / 2 + tol;
    }
    if (o is Furn) {
      final d = w - o.c;
      final r = -o.rot * pi / 180;
      final lx = d.dx * cos(r) - d.dy * sin(r), ly = d.dx * sin(r) + d.dy * cos(r);
      return lx.abs() <= o.w / 2 + tol && ly.abs() <= o.d / 2 + tol;
    }
    if (o is Dim) {
      final l = dimLine(o, doc);
      final v = l[1] - l[0];
      if (v.distance < 1) return false;
      final n = Offset(-v.dy, v.dx) / v.distance;
      return distToSeg(w, l[0] + n * o.off, l[1] + n * o.off) <= tol;
    }
    return false;
  }

  List<Obj> _hitAll(Offset w) {
    final tol = 14 / scale;
    final res = <Obj>[];
    for (final o in doc.objs.reversed) {
      final ly = doc.layerOf(o.layer);
      if (ly != null && (!ly.visible || ly.locked)) continue;
      if (_hit(o, w, tol)) res.add(o);
    }
    res.sort((a, b) => _prio(a).compareTo(_prio(b)));
    return res;
  }

  RoomInfo? _roomAt(Offset w) {
    for (final r in rooms) {
      if (pointInPoly(w, r.poly)) return r;
    }
    return null;
  }

  RoomInfo? _selRoom() => selRoomPt == null ? null : _roomAt(selRoomPt!);

  List<Obj> _selObjs() {
    final out = <Obj>[];
    for (final id in sel) {
      final o = doc.byId(id);
      if (o != null) out.add(o);
    }
    return out;
  }

  List<Obj> _xfObjs() => _selObjs()
      .where((o) => !(o is Opening) && !(o is Dim && o.wallId != null))
      .toList();

  Offset _refOf(Obj o) {
    if (o is Wall) return o.a;
    if (o is Pillar) return o.c;
    if (o is Furn) return o.c;
    if (o is Dim) return o.a;
    return Offset.zero;
  }

  void _shift(Obj o, Offset d) {
    if (o is Wall) {
      o.a += d;
      o.b += d;
    } else if (o is Pillar) {
      o.c += d;
    } else if (o is Furn) {
      o.c += d;
    } else if (o is Dim && o.wallId == null) {
      o.a += d;
      o.b += d;
    }
  }

  void _moveSel(List<Obj> os, Offset d) {
    final ids = {for (final o in os) o.id};
    final pts = <Offset>[];
    for (final o in os) {
      if (o is Wall) {
        pts.add(o.a);
        pts.add(o.b);
      }
    }
    for (final o in os) {
      _shift(o, d);
    }
    for (final w in doc.walls) {
      if (ids.contains(w.id)) continue;
      if (pts.any((p) => (w.a - p).distance < 1)) w.a += d;
      if (pts.any((p) => (w.b - p).distance < 1)) w.b += d;
    }
  }

  void _moveEnds(Offset oldP, Offset np) {
    for (final w in doc.walls) {
      if ((w.a - oldP).distance < 1) w.a = np;
      if ((w.b - oldP).distance < 1) w.b = np;
    }
  }

  Offset _bboxCenter(List<Obj> os) {
    final pts = <Offset>[];
    for (final o in os) {
      if (o is Wall) {
        pts.add(o.a);
        pts.add(o.b);
      } else if (o is Pillar) {
        pts.add(o.c);
      } else if (o is Furn) {
        pts.addAll(furnPoly(o));
      } else if (o is Dim) {
        pts.add(o.a);
        pts.add(o.b);
      }
    }
    if (pts.isEmpty) return Offset.zero;
    var x0 = pts.first.dx, x1 = x0, y0 = pts.first.dy, y1 = y0;
    for (final p in pts) {
      x0 = min(x0, p.dx);
      x1 = max(x1, p.dx);
      y0 = min(y0, p.dy);
      y1 = max(y1, p.dy);
    }
    return Offset((x0 + x1) / 2, (y0 + y1) / 2);
  }

  List<Obj> _dup(List<Obj> src) {
    final map = <String, String>{};
    final out = <Obj>[];
    for (final o in src) {
      if (o is Wall) {
        final n = o.dup(doc.nid());
        map[o.id] = n.id;
        out.add(n);
      }
    }
    for (final o in src) {
      if (o is Wall || o is Opening) continue;
      if (o is Dim && o.wallId != null) continue;
      out.add(o.dup(doc.nid()));
    }
    for (final x in doc.objs) {
      if (x is Opening && map.containsKey(x.wallId)) {
        final n = x.dup(doc.nid()) as Opening;
        n.wallId = map[x.wallId]!;
        out.add(n);
      }
    }
    return out;
  }

  void _setTool(Tool t) {
    setState(() {
      tool = t;
      wallStart = null;
      draftEnd = null;
      dimA = null;
      measA = null;
      measB = null;
      extId = null;
      extTap = null;
    });
  }

  void _addWall(Offset a, Offset b) {
    if ((b - a).distance < 5) return;
    _commit(() {
      doc.objs.add(Wall(doc.nid(), 'Walls', a, b,
          t: wallT, h: wallH, mat: wallT >= 200 ? 'Brick' : 'Plaster'));
      wallStart = b;
      draftEnd = null;
    });
  }

  void _placeOpening(Offset w, bool door) {
    final tol = 18 / scale;
    Wall? best;
    var bd = double.infinity;
    for (final o in doc.objs) {
      if (o is! Wall || !_visible(o)) continue;
      final d = distToSeg(w, o.a, o.b);
      if (d <= max(tol, o.t / 2) && d < bd) {
        bd = d;
        best = o;
      }
    }
    if (best == null) {
      _toast('Tap on a wall to place it');
      return;
    }
    final wl = best;
    final ow = door ? 900.0 : 1200.0;
    if (wl.len < ow + 100) {
      _toast('Wall too short for this opening');
      return;
    }
    final cp = closestOnSeg(w, wl.a, wl.b);
    var pos = (cp - wl.a).distance;
    pos = min(max(pos, ow / 2 + 50), wl.len - ow / 2 - 50);
    for (final o in doc.objs.whereType<Opening>()) {
      if (o.wallId == wl.id && (o.pos - pos).abs() < (o.w + ow) / 2 + 20) {
        _toast('Overlaps another opening');
        return;
      }
    }
    final side = (w - cp).dx * wl.normal.dx + (w - cp).dy * wl.normal.dy;
    _commit(() {
      final op = Opening(doc.nid(), door ? 'Doors' : 'Windows', wl.id, pos,
          w: ow,
          h: door ? 2100 : 1200,
          sill: door ? 0 : 900,
          isDoor: door,
          style: door ? 'single' : 'sliding',
          inward: side >= 0);
      doc.objs.add(op);
      sel = {op.id};
      tool = Tool.select;
    });
  }

  void _doExtend(Wall boundary) {
    final t = doc.wall(extId ?? '');
    if (t == null || identical(t, boundary)) {
      _toast('Pick a different boundary wall');
      return;
    }
    final x = segParams(t.a, t.b - t.a, boundary.a, boundary.b - boundary.a);
    if (x == null) {
      _toast('Walls are parallel');
      return;
    }
    final p = t.a + (t.b - t.a) * x[0];
    final tap = extTap ?? t.mid;
    final moveA = (tap - t.a).distance < (tap - t.b).distance;
    _commit(() {
      if (moveA) {
        t.a = p;
      } else {
        t.b = p;
      }
      extId = null;
      extTap = null;
    });
  }
  void _onTap(Offset sp) {
    final w = _tw(sp);
    switch (tool) {
      case Tool.select:
        final hits = _hitAll(w);
        setState(() {
          selRoomPt = null;
          if (hits.isEmpty) {
            if (_roomAt(w) != null) selRoomPt = w;
            if (!multi) sel = {};
          } else {
            final h = hits.first;
            if (multi) {
              sel = {...sel};
              if (sel.contains(h.id)) {
                sel.remove(h.id);
              } else {
                sel.add(h.id);
              }
            } else {
              sel = {h.id};
            }
          }
        });
        break;
      case Tool.wall:
        final sn = _snap(w, from: wallStart);
        setState(() {
          snapMark = sn;
          wallStart ??= sn.p;
        });
        if (wallStart != null && (sn.p - wallStart!).distance > 5) {
          _addWall(wallStart!, sn.p);
        }
        break;
      case Tool.door:
        _placeOpening(w, true);
        break;
      case Tool.window:
        _placeOpening(w, false);
        break;
      case Tool.column:
        final sn = _snap(w);
        _commit(() => doc.objs.add(Pillar(doc.nid(), 'Columns', sn.p)));
        break;
      case Tool.dim:
        final sn = _snap(w, from: dimA);
        if (dimA == null) {
          setState(() => dimA = sn.p);
        } else {
          final a = dimA!;
          if ((sn.p - a).distance > 5) {
            _commit(() {
              doc.objs.add(Dim(doc.nid(), 'Dimensions', null, a, sn.p, 600));
              dimA = null;
            });
          } else {
            setState(() => dimA = null);
          }
        }
        break;
      case Tool.measure:
        final sn = _snap(w, from: measA);
        setState(() {
          if (measA == null || measB != null) {
            measA = sn.p;
            measB = null;
          } else {
            measB = sn.p;
          }
        });
        break;
      case Tool.extend:
        final hits = _hitAll(w).whereType<Wall>().toList();
        if (hits.isEmpty) {
          _toast('Tap a wall');
          return;
        }
        if (extId == null) {
          setState(() {
            extId = hits.first.id;
            extTap = w;
            sel = {hits.first.id};
          });
          _toast('Now tap the boundary wall');
        } else {
          _doExtend(hits.first);
        }
        break;
      case Tool.pan:
        break;
    }
  }

  Future<void> _onLong(Offset sp, Offset global) async {
    if (view3d) return;
    final w = _tw(sp);
    final hits = _hitAll(w);
    final items = <PopupMenuEntry<String>>[
      if (hits.isNotEmpty)
        PopupMenuItem(value: 'pick', child: Text('Select overlapping (${hits.length})')),
      if (hits.isNotEmpty) const PopupMenuItem(value: 'props', child: Text('Properties')),
      if (hits.isNotEmpty) const PopupMenuItem(value: 'copy', child: Text('Copy…')),
      if (hits.isNotEmpty) const PopupMenuItem(value: 'del', child: Text('Delete')),
      const PopupMenuItem(value: 'start', child: Text('Start wall here')),
      const PopupMenuItem(value: 'fit', child: Text('Zoom to fit')),
    ];
    final r = await showMenu<String>(
        context: context,
        position: RelativeRect.fromLTRB(global.dx, global.dy, global.dx + 1, global.dy + 1),
        items: items);
    if (r == null || !mounted) return;
    switch (r) {
      case 'pick':
        final pick = await showModalBottomSheet<Obj>(
            context: context,
            backgroundColor: kPanel,
            builder: (ctx) => ListView(children: [
                  for (final h in hits)
                    ListTile(
                        dense: true,
                        title: Text(_describe(h)),
                        onTap: () => Navigator.pop(ctx, h)),
                ]));
        if (pick != null) setState(() => sel = {pick.id});
        break;
      case 'props':
        setState(() => sel = {hits.first.id});
        await _editSelected();
        break;
      case 'copy':
        setState(() => sel = {hits.first.id});
        await _cmdCopy();
        break;
      case 'del':
        setState(() => sel = {hits.first.id});
        _delete();
        break;
      case 'start':
        setState(() {
          tool = Tool.wall;
          wallStart = _snap(w).p;
        });
        break;
      case 'fit':
        _fit();
        break;
    }
  }

  void _sStart(ScaleStartDetails d) {
    _mode = '';
    _sFocal = d.localFocalPoint;
    _sOrigin = origin;
    _sScale = scale;
    if (d.pointerCount >= 2) {
      _mode = 'zoom';
      return;
    }
    final w = _tw(d.localFocalPoint);
    _dragW0 = w;
    if (tool == Tool.pan) {
      _mode = 'pan';
      return;
    }
    if (tool == Tool.wall) {
      Offset st;
      if (wallStart != null && (_ts(wallStart!) - d.localFocalPoint).distance < 48) {
        st = wallStart!;
      } else {
        st = _snap(w).p;
      }
      setState(() {
        wallStart = st;
        draftEnd = st;
      });
      _mode = 'wall';
      return;
    }
    if (tool == Tool.select) {
      if (sel.length == 1) {
        final o = doc.byId(sel.first);
        if (o is Wall) {
          for (final isA in [true, false]) {
            final p = isA ? o.a : o.b;
            if ((_ts(p) - d.localFocalPoint).distance < 28) {
              _pushUndo();
              _mode = 'end';
              _endIsA = isA;
              _endCur = p;
              return;
            }
          }
        }
      }
      final hits = _hitAll(w);
      if (hits.isNotEmpty) {
        final h = hits.first;
        if (!sel.contains(h.id)) {
          setState(() {
            sel = {h.id};
            selRoomPt = null;
          });
        }
        _pushUndo();
        if (h is Opening && sel.length == 1) {
          _mode = 'slide';
          _slideId = h.id;
          return;
        }
        _mode = 'move';
        final first = doc.byId(sel.first) ?? h;
        _dragRef = _refOf(first);
        return;
      }
    }
    _mode = 'pan';
  }

  void _sUpdate(ScaleUpdateDetails d) {
    if (d.pointerCount >= 2) {
      if (_mode != 'zoom') {
        _mode = 'zoom';
        _sFocal = d.localFocalPoint;
        _sOrigin = origin;
        _sScale = scale;
        if (draftEnd != null) setState(() => draftEnd = null);
      }
      final ns = (_sScale * d.scale).clamp(0.004, 3.0).toDouble();
      final wf = Offset((_sFocal.dx - _sOrigin.dx) / _sScale,
          (_sFocal.dy - _sOrigin.dy) / _sScale);
      setState(() {
        scale = ns;
        origin = d.localFocalPoint - wf * ns;
      });
      return;
    }
    final fp = d.localFocalPoint;
    setState(() => cursor = _tw(fp));
    switch (_mode) {
      case 'pan':
        setState(() => origin = _sOrigin + (fp - _sFocal));
        break;
      case 'wall':
        final sn = _snap(_tw(fp), from: wallStart);
        setState(() {
          draftEnd = sn.p;
          snapMark = sn;
        });
        break;
      case 'end':
        final o = doc.byId(sel.isEmpty ? '' : sel.first);
        if (o is Wall) {
          final other = _endIsA ? o.b : o.a;
          final sn = _snap(_tw(fp), from: other, ex: {o.id});
          setState(() {
            _moveEnds(_endCur, sn.p);
            _endCur = sn.p;
            snapMark = sn;
            _refresh();
          });
        }
        break;
      case 'move':
        final first = doc.byId(sel.isEmpty ? '' : sel.first);
        if (first == null) break;
        final desired = _dragRef + (_tw(fp) - _dragW0);
        final sn = _snap(desired, ex: sel);
        final delta = sn.p - _refOf(first);
        if (delta.distance > 0) {
          setState(() {
            _moveSel(_selObjs(), delta);
            snapMark = sn;
            _refresh();
          });
        }
        break;
      case 'slide':
        final op = doc.byId(_slideId ?? '');
        if (op is Opening) {
          final wl = doc.wall(op.wallId);
          if (wl != null) {
            final dd = _tw(fp) - wl.a;
            var pos = dd.dx * wl.dir.dx + dd.dy * wl.dir.dy;
            pos = min(max(pos, op.w / 2 + 50), max(op.w / 2 + 50, wl.len - op.w / 2 - 50));
            setState(() {
              op.pos = pos;
              ver++;
            });
          }
        }
        break;
    }
  }

  void _sEnd(ScaleEndDetails d) {
    if (_mode == 'wall') {
      final a = wallStart, b = draftEnd;
      if (a != null && b != null && (b - a).distance * scale >= 18) {
        _addWall(a, b);
      } else {
        setState(() => draftEnd = null);
      }
    } else if (_mode == 'move' || _mode == 'end' || _mode == 'slide') {
      _refresh();
      _touchSave();
    }
    _mode = '';
    setState(() => snapMark = null);
  }

  Future<List<double>?> _ask(
      String title, List<String> labels, List<double> init) async {
    String t(double v) => v.toStringAsFixed(3).replaceFirst(RegExp(r'\.?0+$'), '');
    final cs = [for (final v in init) TextEditingController(text: t(v))];
    return showDialog<List<double>>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(title),
              content: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                for (int i = 0; i < labels.length; i++)
                  TextField(
                      controller: cs[i],
                      autofocus: i == 0,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true, signed: true),
                      decoration: InputDecoration(labelText: labels[i])),
              ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, [
                          for (final c in cs) double.tryParse(c.text.trim()) ?? 0.0
                        ]),
                    child: const Text('OK')),
              ],
            ));
  }

  Future<String?> _askText(String title, String init) {
    final c = TextEditingController(text: init);
    return showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
              title: Text(title),
              content: TextField(controller: c, autofocus: true),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel')),
                FilledButton(
                    onPressed: () => Navigator.pop(ctx, c.text.trim()),
                    child: const Text('OK')),
              ],
            ));
  }

  Future<String?> _pickFromList(String title, List<String> items, String cur) {
    return showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(title: Text(title), children: [
              for (final s in items)
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, s),
                    child: Row(children: [
                      Icon(s == cur ? Icons.radio_button_checked : Icons.radio_button_off,
                          size: 18),
                      const SizedBox(width: 10),
                      Text(s),
                    ])),
            ]));
  }

  void _delete() {
    if (sel.isEmpty) return;
    _commit(() {
      final ids = {...sel};
      for (final w in doc.walls.where((w) => ids.contains(w.id)).toList()) {
        ids.addAll(doc.objs.whereType<Opening>().where((x) => x.wallId == w.id).map((x) => x.id));
        ids.addAll(doc.objs.whereType<Dim>().where((x) => x.wallId == w.id).map((x) => x.id));
      }
      doc.objs.removeWhere((o) => ids.contains(o.id));
      sel = {};
    });
  }

  Future<void> _editSelected() async {
    final os = _selObjs();
    if (os.isEmpty) return _toast('Select an object first');
    final o = os.first;
    if (o is Wall) {
      await _editWall(o);
    } else if (o is Opening) {
      await _editOpening(o);
    } else if (o is Pillar) {
      await _editPillar(o);
    } else if (o is Furn) {
      await _editFurn(o);
    } else {
      _toast('Nothing editable here');
    }
  }

  Future<void> _editWall(Wall w) async {
    final r = await _ask('Wall', ['Length ($_u)', 'Thickness (mm)', 'Height (mm)'],
        [w.len / _f, w.t, w.h]);
    if (r == null) return;
    final mat = await _pickFromList('Material', kMaterials.keys.toList(), w.mat);
    _commit(() {
      final dir = w.dir;
      final newLen = r[0] * _f;
      if (newLen > 1) {
        final oldB = w.b;
        final newB = w.a + dir * newLen;
        _moveEnds(oldB, newB);
      }
      w.t = max(10, r[1]);
      w.h = max(100, r[2]);
      if (mat != null) w.mat = mat;
    });
  }

  Future<void> _editOpening(Opening o) async {
    final r = await _ask(
        o.isDoor ? 'Door' : 'Window',
        ['Width ($_u)', 'Height ($_u)', 'Sill height ($_u)', 'Position along wall ($_u)'],
        [o.w / _f, o.h / _f, o.sill / _f, o.pos / _f]);
    if (r == null) return;
    final wl = doc.wall(o.wallId);
    _commit(() {
      o.w = max(200, r[0] * _f);
      o.h = max(200, r[1] * _f);
      o.sill = max(0, r[2] * _f);
      final maxPos = wl == null ? r[3] * _f : wl.len - o.w / 2 - 50;
      o.pos = min(max(r[3] * _f, o.w / 2 + 50), max(o.w / 2 + 50, maxPos));
    });
  }

  Future<void> _editPillar(Pillar p) async {
    final r = await _ask('Column', ['Width (mm)', 'Depth (mm)', 'Height (mm)'],
        [p.w, p.d, p.h]);
    if (r == null) return;
    _commit(() {
      p.w = max(50, r[0]);
      p.d = max(50, r[1]);
      p.h = max(100, r[2]);
    });
  }

  Future<void> _editFurn(Furn f) async {
    final r = await _ask('Furniture: ${f.kind}',
        ['Width (mm)', 'Depth (mm)', 'Height (mm)', 'Rotation (°)'],
        [f.w, f.d, f.h, f.rot]);
    if (r == null) return;
    _commit(() {
      f.w = max(100, r[0]);
      f.d = max(100, r[1]);
      f.h = max(100, r[2]);
      f.rot = r[3];
    });
  }
  Future<void> _editRoom(RoomInfo r) async {
    final nameC = TextEditingController(text: r.name);
    final ceilC = TextEditingController(
        text: ((r.tag?.ceil ?? wallH) / _f).toStringAsFixed(2));
    String floor = r.tag?.floor ?? 'Ceramic';
    String wallFin = r.tag?.wallFin ?? 'Paint';
    bool showArea = r.tag?.showArea ?? true;
    bool showDims = r.tag?.showDims ?? true;
    final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => StatefulBuilder(
              builder: (ctx, setS) => AlertDialog(
                title: Text('Room ${r.index}'),
                content: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    TextField(
                        controller: nameC,
                        decoration: const InputDecoration(labelText: 'Room name')),
                    TextField(
                        controller: ceilC,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: InputDecoration(labelText: 'Ceiling height ($_u)')),
                    ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Floor finish'),
                        trailing: Text(floor),
                        onTap: () async {
                          final v = await _pickFromList(
                              'Floor finish', kMaterials.keys.toList(), floor);
                          if (v != null) setS(() => floor = v);
                        }),
                    ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Wall finish'),
                        trailing: Text(wallFin),
                        onTap: () async {
                          final v = await _pickFromList(
                              'Wall finish', kMaterials.keys.toList(), wallFin);
                          if (v != null) setS(() => wallFin = v);
                        }),
                    SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Show area'),
                        value: showArea,
                        onChanged: (v) => setS(() => showArea = v)),
                    SwitchListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Show dimensions'),
                        value: showDims,
                        onChanged: (v) => setS(() => showDims = v)),
                    Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                            'Area ${fmtArea(r.area, doc.unit)}  ·  Perimeter ${fmtLen(r.perim, doc.unit, doc.prec)}'
                            '${r.net.isNaN ? '' : '\nNet usable ${fmtArea(r.net, doc.unit)}'}',
                            style: const TextStyle(color: Colors.white60, fontSize: 12))),
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      child: const Text('Cancel')),
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: const Text('Save')),
                ],
              ),
            ));
    if (ok != true) return;
    final ceilMm = (double.tryParse(ceilC.text.trim()) ?? 0) * _f;
    _commit(() {
      var t = r.tag;
      if (t == null) {
        t = RoomTag(r.center, nameC.text.trim().toUpperCase());
        doc.tags.add(t);
      }
      t.name = nameC.text.trim().isEmpty ? r.name : nameC.text.trim().toUpperCase();
      t.floor = floor;
      t.wallFin = wallFin;
      t.showArea = showArea;
      t.showDims = showDims;
      if (ceilMm > 500) t.ceil = ceilMm;
    });
  }

  Future<void> _cmdMove() async {
    final os = _xfObjs();
    if (os.isEmpty) return _toast('Select objects first');
    final r = await _ask('Move', ['ΔX ($_u, right +)', 'ΔY ($_u, up +)'], [0, 0]);
    if (r == null) return;
    _commit(() => _moveSel(os, Offset(r[0] * _f, -r[1] * _f)));
  }

  Future<void> _cmdCopy() async {
    final os = _xfObjs();
    if (os.isEmpty) return _toast('Select objects first');
    final r = await _ask('Copy', ['ΔX ($_u, right +)', 'ΔY ($_u, up +)'], [1000 / _f, 0]);
    if (r == null) return;
    _commit(() {
      final nw = _dup(os);
      final d = Offset(r[0] * _f, -r[1] * _f);
      for (final o in nw) {
        _shift(o, d);
      }
      doc.objs.addAll(nw);
      sel = {for (final o in nw) if (o is! Opening) o.id};
    });
  }

  Future<void> _cmdRotate() async {
    final os = _xfObjs();
    if (os.isEmpty) return _toast('Select objects first');
    final r = await _ask('Rotate (counter-clockwise)', ['Angle (°)'], [90]);
    if (r == null) return;
    _commit(() {
      final rad = -r[0] * pi / 180;
      final c = _bboxCenter(os);
      final quarter = rad / (pi / 2);
      final swap = (quarter - quarter.round()).abs() < 1e-6 && quarter.round().isOdd;
      for (final o in os) {
        if (o is Wall) {
          o.a = rotAbout(o.a, c, rad);
          o.b = rotAbout(o.b, c, rad);
        } else if (o is Pillar) {
          o.c = rotAbout(o.c, c, rad);
          if (swap) {
            final t = o.w;
            o.w = o.d;
            o.d = t;
          }
        } else if (o is Furn) {
          o.c = rotAbout(o.c, c, rad);
          o.rot += rad * 180 / pi;
        } else if (o is Dim) {
          o.a = rotAbout(o.a, c, rad);
          o.b = rotAbout(o.b, c, rad);
        }
      }
    });
  }

  Future<void> _cmdMirror() async {
    final os = _xfObjs();
    if (os.isEmpty) return _toast('Select objects first');
    final r = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(title: const Text('Mirror'), children: [
              for (final e in const {
                'v': 'Move: about vertical axis',
                'h': 'Move: about horizontal axis',
                'vc': 'Copy: about vertical axis',
                'hc': 'Copy: about horizontal axis'
              }.entries)
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(ctx, e.key),
                    child: Text(e.value)),
            ]));
    if (r == null) return;
    final vertical = r.startsWith('v');
    final copy = r.endsWith('c');
    _commit(() {
      final c = _bboxCenter(os);
      final targets = copy ? _dup(os) : os;
      Offset m(Offset p) => vertical
          ? Offset(2 * c.dx - p.dx, p.dy)
          : Offset(p.dx, 2 * c.dy - p.dy);
      final wallIds = <String>{};
      for (final o in targets) {
        if (o is Wall) {
          o.a = m(o.a);
          o.b = m(o.b);
          wallIds.add(o.id);
        } else if (o is Pillar) {
          o.c = m(o.c);
        } else if (o is Furn) {
          o.c = m(o.c);
          o.rot = vertical ? 180 - o.rot : -o.rot;
        } else if (o is Dim && o.wallId == null) {
          o.a = m(o.a);
          o.b = m(o.b);
        }
      }
      for (final o in doc.objs) {
        if (o is Opening && wallIds.contains(o.wallId)) o.inward = !o.inward;
      }
      if (copy) {
        doc.objs.addAll(targets);
        sel = {for (final o in targets) if (o is! Opening) o.id};
      }
    });
  }

  Future<void> _cmdOffset() async {
    final ws = _selObjs().whereType<Wall>().toList();
    if (ws.isEmpty) return _toast('Select wall(s) first');
    final r = await _ask('Offset wall', ['Distance ($_u, negative = other side)'],
        [3000 / _f]);
    if (r == null) return;
    _commit(() {
      final nw = <Obj>[];
      for (final w in ws) {
        final n = w.normal * (r[0] * _f);
        nw.add(Wall(doc.nid(), w.layer, w.a + n, w.b + n,
            t: w.t, h: w.h, mat: w.mat, bearing: w.bearing));
      }
      doc.objs.addAll(nw);
      sel = {for (final o in nw) o.id};
    });
  }

  Future<void> _cmdSplit() async {
    final ws = _selObjs().whereType<Wall>().toList();
    if (ws.length != 1) return _toast('Select exactly one wall');
    final w = ws.first;
    final r = await _ask('Split wall', ['Distance from start ($_u)'], [w.len / _f / 2]);
    if (r == null) return;
    final d = r[0] * _f;
    if (d < 50 || d > w.len - 50) return _toast('Split point must be inside the wall');
    _commit(() {
      final p = w.a + w.dir * d;
      final nw = Wall(doc.nid(), w.layer, p, w.b,
          t: w.t, h: w.h, mat: w.mat, bearing: w.bearing);
      w.b = p;
      for (final o in doc.objs.whereType<Opening>()) {
        if (o.wallId == w.id && o.pos >= d) {
          o.wallId = nw.id;
          o.pos -= d;
        }
      }
      doc.objs.add(nw);
    });
  }

  void _reverseWall(Wall w) {
    final len = w.len;
    final t = w.a;
    w.a = w.b;
    w.b = t;
    for (final o in doc.objs.whereType<Opening>()) {
      if (o.wallId == w.id) {
        o.pos = len - o.pos;
        o.flip = !o.flip;
        o.inward = !o.inward;
      }
    }
  }

  void _cmdReverse() {
    final ws = _selObjs().whereType<Wall>().toList();
    if (ws.isEmpty) return _toast('Select wall(s) first');
    _commit(() {
      for (final w in ws) {
        _reverseWall(w);
      }
    });
  }

  void _cmdMerge() {
    final ws = _selObjs().whereType<Wall>().toList();
    if (ws.length != 2) return _toast('Select exactly two walls');
    var w1 = ws[0], w2 = ws[1];
    final cr = w1.dir.dx * w2.dir.dy - w1.dir.dy * w2.dir.dx;
    if (cr.abs() > 0.01) return _toast('Walls must be collinear');
    if ((w1.b - w2.a).distance > 1) {
      final t = w1;
      w1 = w2;
      w2 = t;
    }
    if ((w1.b - w2.a).distance > 1) return _toast('Walls must share an end');
    _commit(() {
      final l1 = w1.len;
      for (final o in doc.objs.whereType<Opening>()) {
        if (o.wallId == w2.id) {
          o.wallId = w1.id;
          o.pos += l1;
        }
      }
      doc.objs.removeWhere((o) => o is Dim && o.wallId == w2.id);
      w1.b = w2.b;
      doc.objs.remove(w2);
      sel = {w1.id};
    });
  }

  Future<void> _cmdArray() async {
    final os = _xfObjs();
    if (os.isEmpty) return _toast('Select objects first');
    final r = await _ask('Array',
        ['Columns (X count)', 'Rows (Y count)', 'Spacing X ($_u)', 'Spacing Y ($_u, down +)'],
        [3, 1, 3000 / _f, 3000 / _f]);
    if (r == null) return;
    final cx = max(1, r[0].round()), ry = max(1, r[1].round());
    if (cx * ry > 400) return _toast('Too many copies');
    _commit(() {
      final added = <Obj>[];
      for (int j = 0; j < ry; j++) {
        for (int i = 0; i < cx; i++) {
          if (i == 0 && j == 0) continue;
          final d = Offset(i * r[2] * _f, j * r[3] * _f);
          final nw = _dup(os);
          for (final o in nw) {
            _shift(o, d);
          }
          added.addAll(nw);
        }
      }
      doc.objs.addAll(added);
    });
  }

  void _dimSel() {
    final ws = _selObjs().whereType<Wall>().toList();
    if (ws.isEmpty) return _toast('Select wall(s) first');
    _commit(() {
      for (final w in ws) {
        doc.objs.add(Dim(doc.nid(), 'Dimensions', w.id, w.a, w.b, w.t / 2 + 400));
      }
    });
  }

  void _dimAll() {
    _commit(() {
      for (final w in doc.walls.toList()) {
        final has = doc.objs.any((o) => o is Dim && o.wallId == w.id);
        if (!has) {
          doc.objs.add(Dim(doc.nid(), 'Dimensions', w.id, w.a, w.b, w.t / 2 + 300));
        }
      }
    });
  }

  Future<void> _wallByNumbers() async {
    final r = await _ask('Wall by length and angle',
        ['Length ($_u)', 'Angle (°, 0 = right, 90 = up)'], [3000 / _f, 0]);
    if (r == null) return;
    final from = wallStart ?? _snap(_tw(Offset(cv.width / 2, cv.height / 2))).p;
    final a = r[1] * pi / 180;
    final to = from + Offset(cos(a), -sin(a)) * (r[0] * _f);
    setState(() => wallStart = from);
    _addWall(from, to);
  }

  void _selectAll() => setState(() {
        sel = {
          for (final o in doc.objs)
            if (o is! Opening &&
                !(doc.layerOf(o.layer)?.locked ?? false) &&
                _visible(o))
              o.id
        };
      });

  Future<void> _pickFurn() async {
    final pick = await showModalBottomSheet<FurnDef>(
        context: context,
        backgroundColor: kPanel,
        builder: (ctx) => ListView(children: [
              for (final d in kFurn)
                ListTile(
                    dense: true,
                    title: Text(d.name),
                    subtitle: Text(
                        '${d.w.toStringAsFixed(0)} × ${d.d.toStringAsFixed(0)} mm'),
                    onTap: () => Navigator.pop(ctx, d)),
            ]));
    if (pick == null) return;
    final c = _tw(Offset(cv.width / 2, cv.height / 2));
    _commit(() {
      final f = Furn(doc.nid(), 'Furniture', pick.name, c, pick.w, pick.d, pick.h,
          color: pick.color);
      doc.objs.add(f);
      sel = {f.id};
    });
  }

  String _describe(Obj o) {
    final u = doc.unit, p = doc.prec;
    if (o is Wall) return 'Wall  ${fmtLen(o.len, u, p)} × ${fmtLen(o.t, u, 0)}';
    if (o is Opening) {
      return '${o.isDoor ? 'Door' : 'Window'}  ${fmtLen(o.w, u, p)} × ${fmtLen(o.h, u, p)}';
    }
    if (o is Pillar) return 'Column  ${fmtLen(o.w, u, 0)} × ${fmtLen(o.d, u, 0)}';
    if (o is Furn) return o.kind;
    if (o is Dim) return 'Dimension';
    return o.id;
  }

  Future<void> _layersDialog() async {
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
              builder: (ctx, setS) => AlertDialog(
                title: const Text('Layers'),
                content: SizedBox(
                  width: 320,
                  child: ListView(shrinkWrap: true, children: [
                    for (final l in doc.layers)
                      ListTile(
                        dense: true,
                        leading: CircleAvatar(radius: 6, backgroundColor: l.color),
                        title: Text(l.name),
                        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                          IconButton(
                              icon: Icon(l.visible ? Icons.visibility : Icons.visibility_off),
                              onPressed: () {
                                setS(() => l.visible = !l.visible);
                                setState(() {});
                                _touchSave();
                              }),
                          IconButton(
                              icon: Icon(l.locked ? Icons.lock : Icons.lock_open),
                              onPressed: () {
                                setS(() => l.locked = !l.locked);
                                setState(() {});
                                _touchSave();
                              }),
                        ]),
                      ),
                  ]),
                ),
                actions: [
                  TextButton(
                      onPressed: () async {
                        final n = await _askText('New layer name', '');
                        if (n != null && n.isNotEmpty) {
                          setS(() => doc.layers.add(CadLayer(n, kAccent)));
                          setState(() {});
                          _touchSave();
                        }
                      },
                      child: const Text('Add layer')),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Close')),
                ],
              ),
            ));
  }

  Future<void> _settings() async {
    await showDialog<void>(
        context: context,
        builder: (ctx) => StatefulBuilder(
              builder: (ctx, setS) => AlertDialog(
                title: const Text('Drawing settings'),
                content: SingleChildScrollView(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    ListTile(
                        title: const Text('Units'),
                        trailing: DropdownButton<Unit>(
                            value: doc.unit,
                            underline: const SizedBox(),
                            items: [
                              for (final u in Unit.values)
                                DropdownMenuItem(value: u, child: Text(unitName(u)))
                            ],
                            onChanged: (v) {
                              if (v == null) return;
                              setS(() => doc.unit = v);
                              setState(() {});
                              _touchSave();
                            })),
                    SwitchListTile(
                        dense: true,
                        title: const Text('Show grid'),
                        value: showGrid,
                        onChanged: (v) {
                          setS(() => showGrid = v);
                          setState(() {});
                        }),
                    SwitchListTile(
                        dense: true,
                        title: const Text('Snap to grid'),
                        value: snapGrid,
                        onChanged: (v) {
                          setS(() => snapGrid = v);
                          setState(() {});
                        }),
                    SwitchListTile(
                        dense: true,
                        title: const Text('Snap to objects'),
                        value: snapObj,
                        onChanged: (v) {
                          setS(() => snapObj = v);
                          setState(() {});
                        }),
                    SwitchListTile(
                        dense: true,
                        title: const Text('Ortho / 45° lock'),
                        value: ortho,
                        onChanged: (v) {
                          setS(() => ortho = v);
                          setState(() {});
                        }),
                    SwitchListTile(
                        dense: true,
                        title: const Text('Auto wall dimensions'),
                        value: autoDims,
                        onChanged: (v) {
                          setS(() => autoDims = v);
                          setState(() {});
                        }),
                    SwitchListTile(
                        dense: true,
                        title: const Text('Room labels'),
                        value: roomLabels,
                        onChanged: (v) {
                          setS(() => roomLabels = v);
                          setState(() {});
                        }),
                  ]),
                ),
                actions: [
                  FilledButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('Done')),
                ],
              ),
            ));
  }
  Widget _cb(String label, IconData i, VoidCallback f) => TextButton.icon(
        onPressed: f,
        icon: Icon(i, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 12)),
      );

  Widget _bar(List<Widget> children) => Container(
        margin: const EdgeInsets.fromLTRB(8, 0, 8, 4),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: kPanel,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white12),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(children: children),
        ),
      );

  Widget? _ctxBar() {
    if (tool == Tool.wall && wallStart != null) {
      return _bar([
        const Padding(
            padding: EdgeInsets.symmetric(horizontal: 6),
            child: Text('Wall chain',
                style: TextStyle(fontSize: 12, color: Colors.white70))),
        _cb('Length & angle', Icons.straighten, () => _wallByNumbers()),
        _cb('Done', Icons.check, () => setState(() => wallStart = null)),
      ]);
    }
    final room = _selRoom();
    if (room != null && sel.isEmpty) {
      return _bar([
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('${room.name} · ${fmtArea(room.area, doc.unit)}',
                style: const TextStyle(fontSize: 12))),
        _cb('Edit room', Icons.edit, () => _editRoom(room)),
        _cb('Close', Icons.close, () => setState(() => selRoomPt = null)),
      ]);
    }
    final os = _selObjs();
    if (os.isEmpty) return null;
    if (os.length == 1) {
      final o = os.first;
      return _bar([
        Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text(_describe(o), style: const TextStyle(fontSize: 12))),
        _cb('Edit', Icons.edit, () => _editSelected()),
        if (o is Opening)
          _cb('Flip swing', Icons.swap_horiz, () => _commit(() {
                o.inward = !o.inward;
                o.flip = !o.flip;
              })),
        if (o is Wall) _cb('Split', Icons.call_split, () => _cmdSplit()),
        if (o is Wall) _cb('Offset', Icons.open_in_full, () => _cmdOffset()),
        if (o is Wall) _cb('Reverse', Icons.swap_vert, () => _cmdReverse()),
        if (o is Wall) _cb('Dimension', Icons.height, () => _dimSel()),
        _cb('Move', Icons.open_with, () => _cmdMove()),
        _cb('Copy', Icons.copy, () => _cmdCopy()),
        _cb('Rotate', Icons.rotate_right, () => _cmdRotate()),
        _cb('Mirror', Icons.flip, () => _cmdMirror()),
        _cb('Delete', Icons.delete_outline, _delete),
        _cb('Clear', Icons.close, () => setState(() => sel = {})),
      ]);
    }
    return _bar([
      Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Text('${os.length} selected', style: const TextStyle(fontSize: 12))),
      _cb('Move', Icons.open_with, () => _cmdMove()),
      _cb('Copy', Icons.copy, () => _cmdCopy()),
      _cb('Rotate', Icons.rotate_right, () => _cmdRotate()),
      _cb('Mirror', Icons.flip, () => _cmdMirror()),
      _cb('Array', Icons.grid_view, () => _cmdArray()),
      _cb('Merge', Icons.merge, () => _cmdMerge()),
      _cb('Delete', Icons.delete_outline, _delete),
      _cb('Clear', Icons.close, () => setState(() => sel = {})),
    ]);
  }

  Widget _toolBtn(IconData i, String l, bool on, VoidCallback f) => InkWell(
        onTap: f,
        child: SizedBox(
          width: 64,
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Icon(i, color: on ? kAmber : Colors.white70, size: 22),
            const SizedBox(height: 2),
            Text(l,
                style: TextStyle(fontSize: 10, color: on ? kAmber : Colors.white60)),
          ]),
        ),
      );

  Widget _toolRow() => Container(
        color: kPanel,
        height: 62,
        child: ListView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(horizontal: 4),
          children: [
            for (final t in Tool.values)
              _toolBtn(kToolIcon[t]!, kToolLabel[t]!, tool == t, () => _setTool(t)),
            _toolBtn(Icons.chair_outlined, 'Furniture', false, () => _pickFurn()),
            _toolBtn(Icons.edit_outlined, 'Edit', false, () => _editSelected()),
            _toolBtn(Icons.select_all, 'Select all', false, _selectAll),
            _toolBtn(Icons.fit_screen_outlined, 'Fit', false, _fit),
          ],
        ),
      );

  List<Cmd> _commands() => [
        Cmd('WALL', 'Draw walls by tap or drag', () async => _setTool(Tool.wall)),
        Cmd('WALL LENGTH', 'Wall by exact length and angle', () => _wallByNumbers()),
        Cmd('DOOR', 'Place a door on a wall', () async => _setTool(Tool.door)),
        Cmd('WINDOW', 'Place a window on a wall', () async => _setTool(Tool.window)),
        Cmd('COLUMN', 'Place a column', () async => _setTool(Tool.column)),
        Cmd('FURNITURE', 'Insert furniture', () => _pickFurn()),
        Cmd('DIMENSION', 'Dimension between two points', () async => _setTool(Tool.dim)),
        Cmd('DIMENSION WALLS', 'Dimension selected walls', () async => _dimSel()),
        Cmd('DIMENSION ALL', 'Dimension every wall', () async => _dimAll()),
        Cmd('MEASURE', 'Measure distance and angle', () async => _setTool(Tool.measure)),
        Cmd('EXTEND', 'Extend a wall to a boundary wall', () async => _setTool(Tool.extend)),
        Cmd('SELECT ALL', 'Select every visible object', () async => _selectAll()),
        Cmd('MOVE', 'Move selection by ΔX, ΔY', () => _cmdMove()),
        Cmd('COPY', 'Copy selection by offset', () => _cmdCopy()),
        Cmd('ROTATE', 'Rotate selection', () => _cmdRotate()),
        Cmd('MIRROR', 'Mirror selection (move or copy)', () => _cmdMirror()),
        Cmd('OFFSET', 'Offset selected wall', () => _cmdOffset()),
        Cmd('SPLIT', 'Split selected wall at a distance', () => _cmdSplit()),
        Cmd('MERGE', 'Join two collinear walls', () async => _cmdMerge()),
        Cmd('REVERSE', 'Reverse wall direction', () async => _cmdReverse()),
        Cmd('ARRAY', 'Rectangular array of selection', () => _cmdArray()),
        Cmd('PROPERTIES', 'Edit selected object', () => _editSelected()),
        Cmd('DELETE', 'Delete selection', () async => _delete()),
        Cmd('UNDO', 'Undo last change', () async => _undo()),
        Cmd('REDO', 'Redo last undone change', () async => _redo()),
        Cmd('LAYERS', 'Show and lock layers', () => _layersDialog()),
        Cmd('3D VIEW', 'Switch to 3D view', () async => setState(() => view3d = true)),
        Cmd('2D VIEW', 'Switch to 2D drawing', () async => setState(() => view3d = false)),
        Cmd('ZOOM FIT', 'Fit drawing to screen', () async => _fit()),
        Cmd('SETTINGS', 'Units, grid, snapping', () => _settings()),
        Cmd('SAVE', 'Save project on this device', () => _saveNamed()),
      ];

  void _palette() {
    final q = TextEditingController();
    final cmds = _commands();
    showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: kPanel,
        builder: (ctx) => StatefulBuilder(builder: (ctx, setS) {
              final term = q.text.toLowerCase();
              final list = cmds
                  .where((c) =>
                      c.name.toLowerCase().contains(term) ||
                      c.desc.toLowerCase().contains(term))
                  .toList();
              return Padding(
                padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
                child: SizedBox(
                  height: MediaQuery.of(ctx).size.height * 0.6,
                  child: Column(children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: TextField(
                        controller: q,
                        autofocus: true,
                        decoration: const InputDecoration(
                            hintText: 'Search commands: MOVE, WALL, MIRROR…',
                            prefixIcon: Icon(Icons.search)),
                        onChanged: (_) => setS(() {}),
                      ),
                    ),
                    Expanded(
                      child: ListView(children: [
                        for (final c in list)
                          ListTile(
                            dense: true,
                            title: Text(c.name),
                            subtitle: Text(c.desc),
                            onTap: () {
                              Navigator.pop(ctx);
                              c.run();
                            },
                          ),
                        if (list.isEmpty)
                          const ListTile(dense: true, title: Text('No matching command')),
                      ]),
                    ),
                  ]),
                ),
              );
            }));
  }

  Future<void> _copy(String text, String what) async {
    await Clipboard.setData(ClipboardData(text: text));
    _toast('$what copied to clipboard');
  }

  Future<void> _importJson() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final txt = data?.text ?? '';
    try {
      final d = Doc.decode(txt);
      _pushUndo();
      setState(() {
        doc = d;
        sel = {};
        selRoomPt = null;
        _refresh();
      });
      _fit();
      _touchSave();
      _toast('Imported "${d.name}"');
    } catch (_) {
      _toast('Clipboard has no valid project. Copy a project JSON first.');
    }
  }

  String _svg() {
    final ws = doc.walls;
    final pts = [for (final w in ws) ...wallPoly(w, ws)];
    if (pts.isEmpty) return '<svg xmlns="http://www.w3.org/2000/svg"/>';
    var x0 = pts.first.dx, x1 = x0, y0 = pts.first.dy, y1 = y0;
    for (final p in pts) {
      x0 = min(x0, p.dx);
      x1 = max(x1, p.dx);
      y0 = min(y0, p.dy);
      y1 = max(y1, p.dy);
    }
    x0 -= 500;
    y0 -= 500;
    x1 += 500;
    y1 += 500;
    String pp(List<Offset> p) =>
        p.map((q) => '${q.dx.toStringAsFixed(1)},${q.dy.toStringAsFixed(1)}').join(' ');
    final b = StringBuffer()
      ..writeln('<svg xmlns="http://www.w3.org/2000/svg" viewBox="$x0 $y0 ${x1 - x0} ${y1 - y0}" width="${x1 - x0}mm" height="${y1 - y0}mm">')
      ..writeln('<rect x="$x0" y="$y0" width="${x1 - x0}" height="${y1 - y0}" fill="white"/>');
    for (final w in ws) {
      b.writeln('<polygon points="${pp(wallPoly(w, ws))}" fill="#c8c8c8" stroke="black" stroke-width="12"/>');
    }
    for (final o in doc.objs.whereType<Opening>()) {
      final w = doc.wall(o.wallId);
      if (w == null) continue;
      final cc = w.a + w.dir * o.pos;
      final u = w.dir * (o.w / 2);
      final n = w.normal * (w.t / 2 + 2);
      b.writeln('<polygon points="${pp([cc - u + n, cc + u + n, cc + u - n, cc - u - n])}" fill="white"/>');
    }
    for (final p in doc.objs.whereType<Pillar>()) {
      b.writeln('<polygon points="${pp(pillarPoly(p))}" fill="#888" stroke="black" stroke-width="6"/>');
    }
    for (final f in doc.objs.whereType<Furn>()) {
      b.writeln('<polygon points="${pp(furnPoly(f))}" fill="none" stroke="#666" stroke-width="8"/>');
    }
    b.writeln('</svg>');
    return b.toString();
  }

  String _csv() {
    final b = StringBuffer(
        'type,id,name,length_mm,thickness_mm,width_mm,height_mm,depth_mm,area_sqm\n');
    for (final w in doc.walls) {
      b.writeln(
          'wall,${w.id},,${w.len.toStringAsFixed(0)},${w.t.toStringAsFixed(0)},,${w.h.toStringAsFixed(0)},,');
    }
    for (final o in doc.objs.whereType<Opening>()) {
      b.writeln(
          '${o.isDoor ? 'door' : 'window'},${o.id},,,,${o.w.toStringAsFixed(0)},${o.h.toStringAsFixed(0)},,');
    }
    for (final p in doc.objs.whereType<Pillar>()) {
      b.writeln(
          'column,${p.id},,,,${p.w.toStringAsFixed(0)},${p.h.toStringAsFixed(0)},${p.d.toStringAsFixed(0)},');
    }
    for (final r in rooms) {
      final nm = r.name.replaceAll(',', ' ');
      b.writeln('room,${r.index},$nm,,,,,,${(r.area / 1e6).toStringAsFixed(2)}');
    }
    return b.toString();
  }

  Future<void> _menu(String v) async {
    switch (v) {
      case 'new':
        await _newProject();
        break;
      case 'open':
        await _openProject();
        break;
      case 'save':
        await _saveNamed();
        break;
      case 'name':
        final n = await _askText('Project name', doc.name);
        if (n != null && n.isNotEmpty) {
          setState(() => doc.name = n);
          _touchSave();
        }
        break;
      case 'template':
        _pushUndo();
        setState(() {
          _loadTemplate();
          sel = {};
          _refresh();
        });
        _fit();
        _touchSave();
        break;
      case 'import':
        await _importJson();
        break;
      case 'svg':
        await _copy(_svg(), 'SVG');
        break;
      case 'json':
        await _copy(doc.encode(), 'Project JSON');
        break;
      case 'csv':
        await _copy(_csv(), 'Schedule CSV');
        break;
      case 'settings':
        await _settings();
        break;
      case 'fit':
        _fit();
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final bar = _ctxBar();
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 54,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(doc.name,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                overflow: TextOverflow.ellipsis),
            Text(dirty ? 'Saving…' : 'All changes saved',
                style: const TextStyle(fontSize: 10, color: Colors.white54)),
          ],
        ),
        actions: [
          IconButton(
              icon: const Icon(Icons.undo),
              tooltip: 'Undo',
              onPressed: undoS.isEmpty ? null : _undo),
          IconButton(
              icon: const Icon(Icons.redo),
              tooltip: 'Redo',
              onPressed: redoS.isEmpty ? null : _redo),
          IconButton(
              icon: const Icon(Icons.search), tooltip: 'Commands', onPressed: _palette),
          IconButton(
              icon: Icon(multi ? Icons.checklist : Icons.check_box_outline_blank),
              tooltip: 'Multi-select',
              onPressed: () => setState(() => multi = !multi)),
          IconButton(
              icon: const Icon(Icons.layers_outlined),
              tooltip: 'Layers',
              onPressed: _layersDialog),
          IconButton(
              icon: Icon(view3d ? Icons.edit_outlined : Icons.view_in_ar),
              tooltip: '2D / 3D',
              onPressed: () => setState(() => view3d = !view3d)),
          PopupMenuButton<String>(
            onSelected: _menu,
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'new', child: Text('New project')),
              PopupMenuItem(value: 'open', child: Text('Open project')),
              PopupMenuItem(value: 'save', child: Text('Save')),
              PopupMenuItem(value: 'name', child: Text('Rename project')),
              PopupMenuItem(value: 'template', child: Text('Load 2BHK template')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'import', child: Text('Import project (from clipboard)')),
              PopupMenuItem(value: 'svg', child: Text('Export SVG (to clipboard)')),
              PopupMenuItem(value: 'json', child: Text('Export project JSON')),
              PopupMenuItem(value: 'csv', child: Text('Export schedules CSV')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'settings', child: Text('Drawing settings')),
              PopupMenuItem(value: 'fit', child: Text('Zoom to fit')),
            ],
          ),
        ],
      ),
      body: LayoutBuilder(builder: (context, c) {
        cv = c.biggest;
        return Stack(children: [
          if (view3d)
            Positioned.fill(child: View3D(doc: doc, rooms: rooms, ver: ver))
          else
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapUp: (d) => _onTap(d.localPosition),
                onLongPressStart: (d) => _onLong(d.localPosition, d.globalPosition),
                onScaleStart: _sStart,
                onScaleUpdate: _sUpdate,
                onScaleEnd: _sEnd,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: PlanPainter(
                    doc: doc,
                    rooms: rooms,
                    s: scale,
                    o: origin,
                    sel: sel,
                    selRoomPt: selRoomPt,
                    wallStart: wallStart,
                    draftEnd: draftEnd,
                    dimA: dimA,
                    measA: measA,
                    measB: measB,
                    snap: snapMark,
                    showGrid: showGrid,
                    autoDims: autoDims,
                    roomLabels: roomLabels,
                    wallT: wallT,
                  ),
                ),
              ),
            ),
          if (!view3d && cursor != null)
            Positioned(
              top: 6,
              left: 8,
              child: IgnorePointer(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                      color: kPanel.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(6)),
                  child: Text(
                    'X ${fmtLen(cursor!.dx, doc.unit, doc.prec)}   Y ${fmtLen(-cursor!.dy, doc.unit, doc.prec)}',
                    style: const TextStyle(fontSize: 11, color: Colors.white70),
                  ),
                ),
              ),
            ),
          if (!view3d)
            Positioned(
              top: 6,
              right: 8,
              child: IgnorePointer(
                child: Text(
                  multi ? 'MULTI' : '',
                  style: const TextStyle(fontSize: 11, color: kAmber),
                ),
              ),
            ),
        ]);
      }),
      bottomNavigationBar: view3d
          ? null
          : SafeArea(
              top: false,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                if (bar != null) Padding(padding: const EdgeInsets.only(top: 4), child: bar),
                _toolRow(),
              ]),
            ),
    );
  }
}
