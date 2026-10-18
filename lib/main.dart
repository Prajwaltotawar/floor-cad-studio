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

  // ───────────── lifecycle / persistence ─────────────
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

  // ───────────── coordinates / document ops ─────────────
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

  // ───────────── snapping ─────────────
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

  // ───────────── hit testing / selection ─────────────
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

  /// Moves objects and drags along the endpoints of unselected walls that
  /// touch the moved wall ends, so connected walls stay joined.
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

  // ───────────── drawing actions ─────────────
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
                         
