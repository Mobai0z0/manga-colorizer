import 'colorize.dart';

/// 角色色板的一个部位条目。
class PalettePart {
  final String role;
  final String name;
  final int r;
  final int g;
  final int b;
  final String usage;

  const PalettePart({
    required this.role,
    required this.name,
    required this.r,
    required this.g,
    required this.b,
    required this.usage,
  });

  factory PalettePart.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('palette part 必须是对象');
    }
    final hex = json['hex'];
    if (hex is! String) {
      throw const FormatException('palette part.hex 必须是 "#RRGGBB" 字符串');
    }
    final (r, g, b) = parseHexColor(hex);
    final role = json['role'];
    if (role is! String || role.isEmpty) {
      throw const FormatException('palette part.role 必须是非空字符串');
    }
    return PalettePart(
      role: role,
      name: (json['name'] as String?) ?? role,
      r: r,
      g: g,
      b: b,
      usage: (json['usage'] as String?) ?? '',
    );
  }

  Map<String, Object> toJson() => {
        'role': role,
        'name': name,
        'hex': toHexColor(r, g, b),
        'usage': usage,
      };
}

/// 角色色板档案: 同一角色在所有图中复用同一组色值。
class CharacterPalette {
  final String characterId;
  final String displayName;
  final List<PalettePart> parts;

  const CharacterPalette({
    required this.characterId,
    required this.displayName,
    required this.parts,
  });

  factory CharacterPalette.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('character palette 必须是对象');
    }
    final id = json['characterId'];
    if (id is! String || id.isEmpty) {
      throw const FormatException('characterId 必须是非空字符串');
    }
    final rawParts = json['parts'];
    if (rawParts is! List || rawParts.isEmpty) {
      throw const FormatException('parts 必须是非空数组');
    }
    return CharacterPalette(
      characterId: id,
      displayName: (json['displayName'] as String?) ?? id,
      parts: [for (final p in rawParts) PalettePart.fromJson(p)],
    );
  }

  /// 按角色部位 role 取条目 (取第一个匹配)。
  PalettePart partByRole(String role) {
    for (final p in parts) {
      if (p.role == role) return p;
    }
    throw StateError('色板 $characterId 中没有 role=$role 的部位');
  }

  Map<String, Object> toJson() => {
        'characterId': characterId,
        'displayName': displayName,
        'parts': [for (final p in parts) p.toJson()],
      };
}

/// 提示点槽位: 一张图里某个部位所在的坐标 (颜色由色板提供)。
class HintSlot {
  final String role;
  final int x;
  final int y;

  const HintSlot({required this.role, required this.x, required this.y});

  factory HintSlot.fromJson(Object? json) {
    if (json is! Map) throw const FormatException('hint slot 必须是对象');
    final role = json['role'];
    if (role is! String || role.isEmpty) {
      throw const FormatException('slot.role 必须是非空字符串');
    }
    final x = json['x'];
    final y = json['y'];
    if (x is! int || y is! int) {
      throw const FormatException('slot.x/slot.y 必须是整数');
    }
    return HintSlot(role: role, x: x, y: y);
  }
}

/// 由色板 + 槽位生成带 role 的提示点 (颜色严格取自色板,保证跨图统一)。
List<ColorHint> paletteToHints(
    CharacterPalette palette, List<HintSlot> slots) {
  return [
    for (final slot in slots)
      ColorHint(
        x: slot.x,
        y: slot.y,
        r: palette.partByRole(slot.role).r,
        g: palette.partByRole(slot.role).g,
        b: palette.partByRole(slot.role).b,
        role: slot.role,
      ),
  ];
}

/// "#RRGGBB" / "RRGGBB" → (r, g, b)。
(int, int, int) parseHexColor(String hex) {
  var text = hex.trim();
  if (text.startsWith('#')) text = text.substring(1);
  if (text.length != 6) {
    throw FormatException('非法颜色 "$hex": 需要 6 位十六进制');
  }
  final value = int.tryParse(text, radix: 16);
  if (value == null) {
    throw FormatException('非法颜色 "$hex": 含非十六进制字符');
  }
  return ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF);
}

/// (r, g, b) → "#RRGGBB" (大写)。
String toHexColor(int r, int g, int b) =>
    '#${(r << 16 | g << 8 | b).toRadixString(16).toUpperCase().padLeft(6, '0')}';
