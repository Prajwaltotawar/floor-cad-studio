import 'dart:convert';
import 'package:flutter/material.dart';

enum Unit { mm, cm, m, ft, inch }

double unitFactor(Unit u) {
  switch (u) {
    case Unit.mm:
      return 1;
    case Unit.cm:
      return 10;
    case Unit.m:
      return 1000;
    case Unit.ft:
      return 304.8;
    case Unit.inch:
      return 25.4;
  }
}

String unitName(Unit u) => u == Unit.inch ? 'in' : u.name;

int _pr(int p, int hi) => p < 0 ? 0 : (p > hi ? hi : p);

String fmtLen(double mm, Unit u, int prec) {
  switch (u) {
    case Unit.mm:
      return '${mm.toStringAsFixed(0)} mm';
    case Unit.cm:
      return '${(mm / 10).toStringAsFixed(_pr(prec, 3))} cm';
    case Unit.m:
      return '${(mm / 1000).toStringAsFixed(_pr(prec, 4))} m';
    case Unit.inch:
      return '${(mm / 25.4).toStringAsFixed(_pr(prec, 2))} in';
    case Unit.ft:
      final tin = mm / 25.4;
      var ft = (tin / 12).floor();
      var inch = tin - ft * 12;
      if (inch > 11.99) {
        ft += 1;
        inch = 0;
      }
      return "$ft' ${inch.toStringAsFixed(prec > 1 ? 1 : 0)}\"";
  }
}

String fmtArea(double mm2, Unit u) {
  if (u == Unit.ft || u == Unit.inch) {
    return '${(mm2 / 92903.04).toStringAsFixed(1)} ft²';
  }
  return '${(mm2 / 1e6).toStringAsFixed(2)} m²';
}

const Map<String, int> kMaterials = {
  'Brick': 0xFFB5654A,
  'Concrete': 0xFF9AA0A6,
  'Plaster': 0xFFE8E2D6,
  'Wood': 0xFFA67B5B,
  'Marble': 0xFFE9E9EE,
  'Granite': 0xFF55585E,
  'Ceramic': 0xFFD9E3E8,
  'Glass': 0xFF7FC8E8,
  'Steel': 0xFF8A97A5,
  'Aluminum': 0xFFC7CDD3,
  'Paint': 0xFFF2F2F2,
};

Color matColor(String m) => Color(kMaterials[m] ?? 0xFFCCCCCC);

List<double> _o(Offset p) => [p.dx, p.dy];
Offset _oo(dynamic l) => Offset((l[0] as num).toDouble(), (l[1] as num).toDouble());
double _d(dynamic v) => (v as num).toDouble();

class CadLayer {
  String name;
  Color color;
  bool visible;
  bool locked;
  CadLayer(this.name, this.color, {this.visible = true, this.locked = false});
  Map<String, dynamic> toJson() =>
      {'n': name, 'c': color.toARGB32(), 'v': visible, 'l': locked};
  factory CadLayer.fromJson(Map<String, dynamic> j) => CadLayer(
      j['n'] as String, Color(j['c'] as int),
      visible: j['v'] as bool, locked: j['l'] as bool);
}

List<CadLayer> defaultLayers() => [
      CadLayer('Walls', const Color(0xFFE3EAF2)),
      CadLayer('Doors', const Color(0xFFFFB74D)),
      CadLayer('Windows', const Color(0xFF4FC3F7)),
      CadLayer('Columns', const Color(0xFFEF5350)),
      CadLayer('Dimensions', const Color(0xFF69F0AE)),
      CadLayer('Furniture', const Color(0xFFBA68C8)),
      CadLayer('Annotations', const Color(0xFFFFEE58)),
    ];

abstract class Obj {
  String id;
  String layer;
  Obj(this.id, this.layer);
  Map<String, dynamic> toJson();
  Obj dup(String nid) {
    final j = toJson();
    j['id'] = nid;
    return Obj.fromJson(j);
  }

  static Obj fromJson(Map<String, dynamic> j) {
    switch (j['t']) {
      case 'wall':
        return Wall.fromJson(j);
      case 'open':
        return Opening.fromJson(j);
      case 'col':
        return Pillar.fromJson(j);
      case 'furn':
        return Furn.fromJson(j);
      case 'dim':
        return Dim.fromJson(j);
    }
    throw FormatException('Unknown object type ${j['t']}');
  }
}

class Wall extends Obj {
  Offset a, b;
  double t, h;
  String mat;
  bool bearing;
  Wall(String id, String layer, this.a, this.b,
      {this.t = 230, this.h = 3000, this.mat = 'Brick', this.bearing = false})
      : super(id, layer);
  double get len => (b - a).distance;
  Offset get mid => (a + b) / 2;
  Offset get dir {
    final l = len;
    return l < 1e-9 ? const Offset(1, 0) : (b - a) / l;
  }

  Offset get normal => Offset(-dir.dy, dir.dx);
  @override
  Map<String, dynamic> toJson() => {
        't': 'wall', 'id': id, 'ly': layer, 'a': _o(a), 'b': _o(b),
        'th': t, 'h': h, 'm': mat, 'lb': bearing
      };
  factory Wall.fromJson(Map<String, dynamic> j) => Wall(
      j['id'] as String, j['ly'] as String, _oo(j['a']), _oo(j['b']),
      t: _d(j['th']), h: _d(j['h']), mat: j['m'] as String,
      bearing: j['lb'] as bool);
}

class Opening extends Obj {
  String wallId;
  double pos, w, h, sill;
  bool isDoor, flip, inward;
  String style;
  Opening(String id, String layer, this.wallId, this.pos,
      {this.w = 900, this.h = 2100, this.sill = 0, this.isDoor = true,
      this.style = 'single', this.flip = false, this.inward = true})
      : super(id, layer);
  @override
  Map<String, dynamic> toJson() => {
        't': 'open', 'id': id, 'ly': layer, 'wid': wallId, 'p': pos, 'w': w,
        'h': h, 's': sill, 'd': isDoor, 'st': style, 'f': flip, 'in': inward
      };
  factory Opening.fromJson(Map<String, dynamic> j) => Opening(
      j['id'] as String, j['ly'] as String, j['wid'] as String, _d(j['p']),
      w: _d(j['w']), h: _d(j['h']), sill: _d(j['s']), isDoor: j['d'] as bool,
      style: j['st'] as String, flip: j['f'] as bool, inward: j['in'] as bool);
}

class Pillar extends Obj {
  Offset c;
  double w, d, h;
  bool round;
  String mat;
  Pillar(String id, String layer, this.c,
      {this.w = 300, this.d = 300, this.h = 3000, this.round = false,
      this.mat = 'Concrete'})
      : super(id, layer);
  @override
  Map<String, dynamic> toJson() => {
        't': 'col', 'id': id, 'ly': layer, 'c': _o(c), 'w': w, 'd': d, 'h': h,
        'r': round, 'm': mat
      };
  factory Pillar.fromJson(Map<String, dynamic> j) => Pillar(
      j['id'] as String, j['ly'] as String, _oo(j['c']),
      w: _d(j['w']), d: _d(j['d']), h: _d(j['h']), round: j['r'] as bool,
      mat: j['m'] as String);
}

class Furn extends Obj {
  String kind;
  Offset c;
  double w, d, h, rot;
  int color;
  Furn(String id, String layer, this.kind, this.c, this.w, this.d, this.h,
      {this.rot = 0, this.color = 0xFF8E7CC3})
      : super(id, layer);
  @override
  Map<String, dynamic> toJson() => {
        't': 'furn', 'id': id, 'ly': layer, 'k': kind, 'c': _o(c), 'w': w,
        'd': d, 'h': h, 'r': rot, 'col': color
      };
  factory Furn.fromJson(Map<String, dynamic> j) => Furn(
      j['id'] as String, j['ly'] as String, j['k'] as String, _oo(j['c']),
      _d(j['w']), _d(j['d']), _d(j['h']),
      rot: _d(j['r']), color: j['col'] as int);
}

class Dim extends Obj {
  String? wallId;
  Offset a, b;
  double off;
  Dim(String id, String layer, this.wallId, this.a, this.b, this.off)
      : super(id, layer);
  @override
  Map<String, dynamic> toJson() => {
        't': 'dim', 'id': id, 'ly': layer, 'wid': wallId, 'a': _o(a),
        'b': _o(b), 'o': off
      };
  factory Dim.fromJson(Map<String, dynamic> j) => Dim(
      j['id'] as String, j['ly'] as String, j['wid'] as String?,
      _oo(j['a']), _oo(j['b']), _d(j['o']));
}

class RoomTag {
  Offset pos;
  String name, floor, wallFin;
  double ceil;
  bool showArea, showDims;
  RoomTag(this.pos, this.name,
      {this.floor = 'Ceramic', this.wallFin = 'Paint', this.ceil = 3000,
      this.showArea = true, this.showDims = true});
  Map<String, dynamic> toJson() => {
        'p': _o(pos), 'n': name, 'f': floor, 'w': wallFin, 'c': ceil,
        'sa': showArea, 'sd': showDims
      };
  factory RoomTag.fromJson(Map<String, dynamic> j) => RoomTag(
      _oo(j['p']), j['n'] as String,
      floor: j['f'] as String, wallFin: j['w'] as String, ceil: _d(j['c']),
      showArea: j['sa'] as bool, showDims: j['sd'] as bool);
}

class Doc {
  String name = 'Untitled';
  Unit unit = Unit.m;
  int prec = 2;
  double grid = 250;
  List<CadLayer> layers = defaultLayers();
  List<Obj> objs = [];
  List<RoomTag> tags = [];
  int seq = 1;

  String nid() => 'o${seq++}';

  CadLayer? layerOf(String n) {
    for (final l in layers) {
      if (l.name == n) return l;
    }
    return null;
  }

  Obj? byId(String id) {
    for (final o in objs) {
      if (o.id == id) return o;
    }
    return null;
  }

  Wall? wall(String id) {
    final o = byId(id);
    return o is Wall ? o : null;
  }

  List<Wall> get walls => objs.whereType<Wall>().toList();

  String encode() => jsonEncode({
        'v': 1, 'name': name, 'unit': unit.index, 'prec': prec, 'grid': grid,
        'seq': seq,
        'layers': layers.map((e) => e.toJson()).toList(),
        'objs': objs.map((e) => e.toJson()).toList(),
        'tags': tags.map((e) => e.toJson()).toList(),
      });

  static Doc decode(String s) {
    final j = jsonDecode(s) as Map<String, dynamic>;
    final d = Doc();
    d.name = j['name'] as String;
    d.unit = Unit.values[j['unit'] as int];
    d.prec = j['prec'] as int;
    d.grid = _d(j['grid']);
    d.seq = j['seq'] as int;
    d.layers = (j['layers'] as List)
        .map((e) => CadLayer.fromJson(e as Map<String, dynamic>))
        .toList();
    d.objs = (j['objs'] as List)
        .map((e) => Obj.fromJson(e as Map<String, dynamic>))
        .toList();
    d.tags = (j['tags'] as List)
        .map((e) => RoomTag.fromJson(e as Map<String, dynamic>))
        .toList();
    return d;
  }
}
