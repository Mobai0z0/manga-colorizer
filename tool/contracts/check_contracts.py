#!/usr/bin/env python3
"""跨端契约一致性检查（stdlib only，不需要 venv / 权重 / 模型）。

用法:
    python tool/contracts/check_contracts.py

检查项:
  1. 色彩方案表 service.py FINISH_SCHEMES ≡ core finish.dart kFinishSchemes
     （id、顺序、全部参数值逐项相等）；
  2. Web 方案下拉 web/dist/index.html #scheme-select 的 id 与顺序；
  3. 暖纸设计令牌 web/dist/app.css ↔ mobile/lib/theme/warm_tokens.dart
     （浅色/深色共用色 + 莫奈三色）；
  4. Web 手动主题覆盖（html[data-theme]）与系统偏好两套色值一致；
  5. 批量上限 web/dist/app.js MAXN ≡ service.py MAX_BATCH。

退出码: 0 全部一致；1 存在漂移（逐条打印差异）。
"""
from __future__ import annotations

import ast
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SERVICE_PY = ROOT / 'tool/colorizer_service/service.py'
FINISH_DART = ROOT / 'packages/manga_colorizer_core/lib/src/finish.dart'
APP_CSS = ROOT / 'web/dist/app.css'
INDEX_HTML = ROOT / 'web/dist/index.html'
APP_JS = ROOT / 'web/dist/app.js'
WARM_DART = ROOT / 'mobile/lib/theme/warm_tokens.dart'

# 两端共用的暖纸令牌: app.css 变量名（不含 --） → warm_tokens.dart 常量名。
LIGHT_TOKENS = {
    'md-sys-color-surface': 'kParchment',
    'md-sys-color-surface-container': 'kIvory',
    'md-sys-color-on-surface': 'kInk',
    'md-sys-color-on-surface-variant': 'kInkSoft',
    'md-sys-color-outline-variant': 'kCreamLine',
    'md-sys-color-primary': 'kTerracotta',
    'md-sys-color-primary-strong': 'kTerracottaStrong',
    'md-sys-color-tertiary': 'kAmber',
    'md-sys-color-error': 'kBrick',
    'monet-terracotta': 'kMonetTerracotta',
    'monet-sage': 'kMonetSage',
    'monet-sand': 'kMonetSand',
}
DARK_TOKENS = {
    'md-sys-color-surface': 'kCanvasDark',
    'md-sys-color-surface-container': 'kSurfaceDark',
    'md-sys-color-outline-variant': 'kLineDark',
    'md-sys-color-on-surface': 'kInkDark',
    'md-sys-color-on-surface-variant': 'kInkSoftDark',
    'md-sys-color-primary-strong': 'kTerracottaStrongDark',
    'md-sys-color-error': 'kBrickDark',
}

try:  # Windows 控制台可能是 GBK；输出只做可读性用途，不能因编码中断检查。
    sys.stdout.reconfigure(errors='replace')
except Exception:
    pass

_failures: list[str] = []


def fail(message: str) -> None:
    _failures.append(message)


def _read(path: Path) -> str:
    return path.read_text(encoding='utf-8')


def _balanced(text: str, open_index: int, open_ch: str = '{', close_ch: str = '}') -> str:
    """返回从 open_index 处的开括号到匹配闭括号的整段文本。"""
    depth = 0
    for i in range(open_index, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return text[open_index:i + 1]
    raise ValueError(f'{open_index} 处括号未闭合')


def _eval_ast(node: ast.AST):
    if isinstance(node, ast.Constant):
        return node.value
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'dict':
        return {kw.arg: _eval_ast(kw.value) for kw in node.keywords}
    if isinstance(node, (ast.Tuple, ast.List)):
        return tuple(_eval_ast(elt) for elt in node.elts)
    raise ValueError(f'不支持的方案表字面量: {ast.dump(node)}')


def parse_service_schemes() -> dict[str, dict]:
    text = _read(SERVICE_PY)
    match = re.search(r'FINISH_SCHEMES\s*(?::[^=]+)?=\s*\{', text)
    if not match:
        raise ValueError('service.py 未找到 FINISH_SCHEMES')
    body = _balanced(text, text.index('{', match.start()))
    assigned = ast.parse('FINISH_SCHEMES = ' + body).body[0]
    value = getattr(assigned, 'value', None)
    if not isinstance(value, ast.Dict):
        raise ValueError('FINISH_SCHEMES 不是字典字面量')
    return {key.value: _eval_ast(val) for key, val in zip(value.keys, value.values)}


def parse_dart_schemes() -> dict[str, dict]:
    text = _read(FINISH_DART)
    match = re.search(r'kFinishSchemes\s*=\s*\{', text)
    if not match:
        raise ValueError('finish.dart 未找到 kFinishSchemes')
    body = _balanced(text, text.index('{', match.start()))
    schemes: dict[str, dict] = {}
    pos = 0
    for entry in re.finditer(r"'([a-z0-9-]+)'\s*:\s*FinishOptions\(", body):
        if entry.start() < pos:
            continue
        open_index = body.index('(', entry.end() - 1)
        args = _balanced(body, open_index, '(', ')')[1:-1]
        pos = open_index + len(_balanced(body, open_index, '(', ')'))
        values: dict[str, object] = {}
        for arg in re.finditer(r'(\w+)\s*:\s*(-?\d+(?:\.\d+)?|true|false)', args):
            raw = arg.group(2)
            values[arg.group(1)] = (
                raw == 'true' if raw in ('true', 'false') else float(raw))
        schemes[entry.group(1)] = values
    return schemes


def dart_scheme_to_service(values: dict[str, object]) -> dict[str, object]:
    """Dart 具名参数 → service.py 的键名（warmth/paperTone 聚合为元组）。"""
    out: dict[str, object] = {}
    warmth: list[float | None] = [None, None]
    paper_tone: list[float | None] = [None, None, None]
    for key, value in values.items():
        if key == 'warmthA':
            warmth[0] = value
        elif key == 'warmthB':
            warmth[1] = value
        elif key == 'warmthC0':
            out['warmth_c0'] = value
        elif key == 'paperToneR':
            paper_tone[0] = value
        elif key == 'paperToneG':
            paper_tone[1] = value
        elif key == 'paperToneB':
            paper_tone[2] = value
        elif key == 'paperToneStrength':
            out['paper_tone_strength'] = value
        elif key == 'neutralPaper':
            out['neutral_paper'] = value
        elif key in ('gain', 'knee'):
            out[key] = value
        else:
            raise ValueError(f'未知 FinishOptions 参数: {key}')
    if warmth[0] is not None:
        out['warmth'] = tuple(warmth)
    if paper_tone[0] is not None:
        out['paper_tone'] = tuple(int(v) for v in paper_tone)
    return out


def _canon(value):
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return round(float(value), 6)
    if isinstance(value, (tuple, list)):
        return tuple(_canon(item) for item in value)
    return value


def check_schemes() -> tuple[dict[str, dict], list[str]]:
    service = parse_service_schemes()
    dart = {sid: dart_scheme_to_service(vals) for sid, vals in parse_dart_schemes().items()}
    service_ids, dart_ids = list(service), list(dart)
    if service_ids != dart_ids:
        fail(f'方案 id/顺序不一致: service={service_ids} dart={dart_ids}')
    for sid in service_ids:
        if sid not in dart:
            continue
        a, b = _canon(service[sid]), _canon(dart[sid])
        if a != b:
            keys = sorted(set(a) | set(b))
            diff = '; '.join(
                f'{key}: service={a.get(key)!r} dart={b.get(key)!r}'
                for key in keys if a.get(key) != b.get(key))
            fail(f'方案 {sid} 参数不一致: {diff}')
    return service, service_ids


def check_web_schemes(service_ids: list[str]) -> None:
    text = _read(INDEX_HTML)
    block = re.search(r'<select[^>]*id="scheme-select".*?</select>', text, re.S)
    if not block:
        fail('index.html 未找到 #scheme-select')
        return
    web_ids = re.findall(r'<option value="([^"]+)"', block.group(0))
    if web_ids != service_ids:
        fail(f'Web 方案下拉与 service.py 不一致: web={web_ids} service={service_ids}')


def parse_css_blocks(path: Path) -> dict[tuple[str, ...], dict[str, str]]:
    """解析 CSS 声明块: 选择器栈元组 → {变量名: 值}（只收 -- 开头的变量）。"""
    text = re.sub(r'/\*.*?\*/', '', _read(path), flags=re.S)
    blocks: dict[tuple[str, ...], dict[str, str]] = {}
    stack: list[str] = []
    buf = ''
    for char in text:
        if char == '{':
            stack.append(' '.join(buf.split()))
            buf = ''
        elif char == '}':
            if stack:
                stack.pop()
            buf = ''
        elif char == ';':
            decl = buf.strip()
            if stack and decl.startswith('--') and ':' in decl:
                name, _, value = decl.partition(':')
                blocks.setdefault(tuple(stack), {})[name.strip()] = value.strip()
            buf = ''
        else:
            buf += char
    return blocks


def parse_dart_tokens() -> dict[str, str]:
    return {
        match.group(1): match.group(2).lower()
        for match in re.finditer(
            r'const Color (k\w+) = Color\(0xFF([0-9A-Fa-f]{6})\);', _read(WARM_DART))
    }


def _norm_color(value: str | None) -> str | None:
    if value is None:
        return None
    return value.strip().lower().lstrip('#')


def check_tokens(blocks: dict[tuple[str, ...], dict[str, str]]) -> None:
    system_light = blocks.get((':root',), {})
    system_dark = blocks.get(('@media (prefers-color-scheme: dark)', ':root'), {})
    manual_light = blocks.get(("html[data-theme='light']",), {})
    manual_dark = blocks.get(("html[data-theme='dark']",), {})
    dart = parse_dart_tokens()

    for label, css_block, mapping in (
            ('浅色', system_light, LIGHT_TOKENS),
            ('深色', system_dark, DARK_TOKENS)):
        if not css_block:
            fail(f'app.css 缺少{label}令牌块')
            continue
        for var, dart_name in mapping.items():
            css_value = _norm_color(css_block.get('--' + var))
            dart_value = dart.get(dart_name)
            if css_value is None:
                fail(f'{label}: app.css 缺少 --{var}')
            elif dart_value is None:
                fail(f'{label}: warm_tokens.dart 缺少 {dart_name}')
            elif css_value != dart_value:
                fail(f'{label}: --{var}={css_value} 与 {dart_name}={dart_value} 不一致')

    # Web 内部：手动主题覆盖必须与系统偏好的色值一致（排除只在一侧出现的变量）。
    for label, system, manual in (
            ('浅色', system_light, manual_light),
            ('深色', system_dark, manual_dark)):
        common = [
            key for key in (set(system) & set(manual))
            if key.startswith('--md-sys-color-')]
        for key in sorted(common):
            if system[key].strip().lower() != manual[key].strip().lower():
                fail(f'Web {label}主题: 系统偏好 {key}={system[key]} '
                     f'!= 手动主题 {manual[key]}')


def check_batch_limit() -> tuple[int | None, int | None]:
    service_text = _read(SERVICE_PY)
    service_match = re.search(r'^\s*MAX_BATCH = (\d+)$', service_text, re.M)
    web_match = re.search(r'^\s*const MAXN = (\d+);$', _read(APP_JS), re.M)
    if not service_match:
        fail('service.py 未找到 MAX_BATCH')
        return None, None
    if not web_match:
        fail('app.js 未找到 MAXN')
        return None, None
    service_limit = int(service_match.group(1))
    web_limit = int(web_match.group(1))
    if service_limit != web_limit:
        fail(f'批量上限不一致: service.MAX_BATCH={service_limit} web.MAXN={web_limit}')
    return service_limit, web_limit


def main() -> int:
    try:
        service_schemes, service_ids = check_schemes()
        print(f'  [OK]   方案表 service.py <-> finish.dart: {len(service_schemes)} 个 id')
        check_web_schemes(service_ids)
        print(f'  [OK]   方案下拉 index.html <-> service.py: {", ".join(service_ids)}')

        blocks = parse_css_blocks(APP_CSS)
        check_tokens(blocks)
        print(f'  [OK]   暖纸令牌 浅色 {len(LIGHT_TOKENS)} 项 / 深色 {len(DARK_TOKENS)} 项')
        print('  [OK]   Web 手动主题覆盖 <-> 系统偏好色值')

        service_limit, web_limit = check_batch_limit()
        if service_limit is not None:
            print(f'  [OK]   批量上限 MAX_BATCH=MAXN={service_limit}')
    except Exception as exc:  # 解析失败也按漂移处理，避免 CI 静默放行
        fail(f'检查异常: {exc!r}')

    if _failures:
        print('\n发现跨端漂移:')
        for message in _failures:
            print(f'  [FAIL] {message}')
        return 1
    print('\n全部一致。')
    return 0


if __name__ == '__main__':
    sys.exit(main())
