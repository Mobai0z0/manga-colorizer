// ORT C API 表的运行时「自愈重定位」。
//
// 背景（v0.5.22 MuMu x86_64 取证）：部分环境（模拟器/卓易通系）的 linker 对
// libonnxruntime.so 的 RELA 重定位处理有缺陷——OrtApiBase 两槽运行时值不是
// 「base+addend（GetApi 函数地址）」而是**把 addend 位置处的 8 字节文件内容
// 原样抄进了槽位**（实测 slot0=0x1bf883ff428dfa89 == 文件 0xa651e0 处的
// 89 fa 8d 42 ff 83 f8 1b 小端读出）。查表路径第一个被调用的槽函数指针
// （GetVersionString/GetApi）因此跳进代码字节 → SIGSEGV。
//
// 自愈原理（全部运行时可导出，零硬编码、不写内存）：
//   1. load_base：/proc/self/maps 里 libonnxruntime.so 的 offset==0 映射行
//      的 start（两 ABI 的第一 LOAD 都是 vaddr=0/off=0，已实证）。
//   2. OrtApiBase_vaddr = OrtGetApiBase() 返回值 - load_base。
//      OrtGetApiBase 的函数体只用 rip 相对寻址（leaq/adrp+add），**不经过
//      数据重定位**，返回值可信。
//   3. 解析 so 文件的 .rela.dyn（PT_DYNAMIC: DT_RELA/DT_RELASZ），建
//      off→addend 表；取 RELATIVE 条目（x86_64 type=8 / arm64 type=1027）。
//   4. GetApi 运行时地址 = load_base + rela[OrtApiBase_vaddr]（槽 0 的
//      addend 就是 GetApi 的静态 vaddr）；GetVersionString 同理（+8）。
//   5. api = GetApi(27)——GetApi 函数体自洽（版本比较 + leaq OrtApi 表），
//      调用安全；返回值 = load_base + OrtApi_vaddr。
//   6. OrtApi 第 i 槽运行时地址 = load_base + rela[OrtApi_vaddr + i*8]。
//      _bind 全部成员从自算地址 asFunction，绕开坏掉的内存槽值。
//
// 只读 so 文件与 /proc/self/maps，不写任何进程内存；RELA 缺条目时明确报错。
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'backend_log.dart';

/// x86_64 R_X86_64_RELATIVE。
const int _kRelTypeX64 = 8;

/// arm64 R_AARCH64_RELATIVE。
const int _kRelTypeArm64 = 1027;

/// OrtApi 成员数（vendor header ORT_API_VERSION=27 时 412）。
const int _kOrtApiSlots = 412;

class OrtRelocationException implements Exception {
  const OrtRelocationException(this.message);
  final String message;

  @override
  String toString() => 'OrtRelocationException: $message';
}

/// 解析结果：OrtApi 第 i 槽的运行时地址。
class OrtRelocatedApi {
  OrtRelocatedApi._(this.apiSlots);

  /// 长度 = 412；apiSlots[i] = OrtApi 第 i 个成员函数的运行时地址
  /// （Pointer\<Void\> 形态，绑定侧用 fromAddress 重建具体签名指针）。
  final List<Pointer<Void>> apiSlots;
}

/// 从 /proc/self/maps 定位 libonnxruntime.so：返回 (loadBase, filePath)。
/// 只取 offset==0 的映射行（第一 LOAD：file off 0 ↔ vaddr 0）。
({int loadBase, String path}) locateLibrary() {
  final lines = File('/proc/self/maps').readAsLinesSync();
  for (final line in lines) {
    // 形如 `7f2c80000000-7f2c82900000 r--p 00000000 fd:01 12345 /path/libonnxruntime.so`
    final m = RegExp(r'^([0-9a-f]+)-([0-9a-f]+) \S+ ([0-9a-f]+) \S+ \S+ (.+)$')
        .firstMatch(line);
    if (m == null) continue;
    final path = m.group(4)!;
    if (!path.contains('libonnxruntime.so')) continue;
    if (m.group(3) != '00000000') continue; // offset==0
    return (
      loadBase: int.parse(m.group(1)!, radix: 16),
      path: path,
    );
  }
  throw const OrtRelocationException('/proc/self/maps 中未找到 '
      'libonnxruntime.so 的 offset=0 映射');
}

/// 解析 so 文件的 .rela.dyn → off→addend（仅 RELATIVE）。
Map<int, int> _parseRelaRelative(Uint8List so, int rtype) {
  // ELF64: e_phoff@0x20, e_phentsize@0x36, e_phnum@0x38
  final bd = ByteData.sublistView(so);
  final ePhoff = bd.getUint64(0x20, Endian.little);
  final ePhentsize = bd.getUint16(0x36, Endian.little);
  final ePhnum = bd.getUint16(0x38, Endian.little);
  var dynOff = -1;
  for (var i = 0; i < ePhnum; i++) {
    final p = ePhoff + i * ePhentsize;
    final pType = bd.getUint32(p, Endian.little);
    if (pType == 2) {
      // PT_DYNAMIC
      dynOff = bd.getUint64(p + 8, Endian.little); // p_offset
      break;
    }
  }
  if (dynOff < 0) {
    throw const OrtRelocationException('so 无 PT_DYNAMIC');
  }
  var relaOff = -1;
  var relaSz = 0;
  for (var pos = dynOff;; pos += 16) {
    final tag = bd.getInt64(pos, Endian.little);
    final val = bd.getUint64(pos + 8, Endian.little);
    if (tag == 0) break;
    if (tag == 7) relaOff = val; // DT_RELA
    if (tag == 8) relaSz = val; // DT_RELASZ
  }
  if (relaOff < 0 || relaSz == 0) {
    throw const OrtRelocationException('so 无 DT_RELA（重定位表缺失）');
  }
  final out = <int, int>{};
  for (var i = 0; i < relaSz; i += 24) {
    final off = bd.getUint64(relaOff + i, Endian.little);
    final info = bd.getUint64(relaOff + i + 8, Endian.little);
    final addend = bd.getInt64(relaOff + i + 16, Endian.little);
    if ((info & 0xffffffff) == rtype) out[off] = addend;
  }
  return out;
}

/// 自愈主入口：给定 so 文件字节与运行时基址/OrtApiBase vaddr，
/// 返回 OrtApi 全部 412 槽的**修正后**运行时地址。
///
/// [apiBaseAddr] = OrtGetApiBase() 的返回值（运行时指针，可信）。
/// [soPath] = maps 里拿到的文件路径。
OrtRelocatedApi selfRelocate({
  required int loadBase,
  required Pointer<Void> apiBaseAddr,
  required String soPath,
}) {
  final so = File(soPath).readAsBytesSync();
  // 重定位类型按 so 自己的 e_machine 判定（加载的 so 架构与运行时 CPU 一致）。
  final eMachine = ByteData.sublistView(so).getUint16(0x12, Endian.little);
  final type = switch (eMachine) {
    0xb7 => _kRelTypeArm64, // EM_AARCH64
    0x3e => _kRelTypeX64, // EM_X86_64
    0x28 => throw const OrtRelocationException(
        'arm32 libonnxruntime.so 的自愈暂不支持（项目仅 arm64/x86_64 启用 FFI）'),
    _ => throw OrtRelocationException('未知 e_machine=0x'
        '${eMachine.toRadixString(16)}'),
  };
  final rela = _parseRelaRelative(so, type);

  final apiBaseVaddr = apiBaseAddr.address - loadBase;
  if (apiBaseVaddr < 0) {
    throw OrtRelocationException(
        'OrtApiBase vaddr 为负（base=$loadBase, apiBase=$apiBaseVaddr）');
  }
  final getApiVaddr = rela[apiBaseVaddr];
  final getVerVaddr = rela[apiBaseVaddr + 8];
  if (getApiVaddr == null || getVerVaddr == null) {
    throw OrtRelocationException(
        'RELA 缺 OrtApiBase 槽条目（off=$apiBaseVaddr）：自愈不可行');
  }
  backendLog('[ffi-fix] RELA 自愈：GetApi vaddr=0x'
      '${getApiVaddr.toRadixString(16)}、GetVersionString vaddr=0x'
      '${getVerVaddr.toRadixString(16)}');

  // 调 GetApi(27)（函数体自洽），返回 OrtApi 表运行时地址。
  final getApi = Pointer<Void>.fromAddress(loadBase + getApiVaddr)
      .cast<NativeFunction<Pointer<Void> Function(UnsignedInt)>>()
      .asFunction<Pointer<Void> Function(int)>();
  final api = getApi(27);
  if (api == nullptr) {
    throw const OrtRelocationException(
        '自愈 GetApi(27) 返回 null：ORT 版本不支持');
  }
  final apiVaddr = api.address - loadBase;
  backendLog('[ffi-fix] OrtApi 表 vaddr=0x${apiVaddr.toRadixString(16)}');

  final slots = <Pointer<Void>>[];
  for (var i = 0; i < _kOrtApiSlots; i++) {
    final v = rela[apiVaddr + i * 8];
    if (v == null) {
      throw OrtRelocationException('RELA 缺 OrtApi[$i] 条目（off=0x'
          '${(apiVaddr + i * 8).toRadixString(16)}）：自愈不可行');
    }
    slots.add(Pointer<Void>.fromAddress(loadBase + v));
  }
  return OrtRelocatedApi._(slots);
}
