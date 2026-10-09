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
//   1. so 基址：dladdr(OrtGetApiBase 返回的函数指针) 直答 dli_fbase + so
//      路径（Android linker 导出 dladdr，通常经 libdl.so 透传）；失败时回退
//      解析 /proc/self/maps：so 以**未压缩**形式存于 base.apk 内（AGP
//      useLegacyPackaging=false，16KB 对齐），映射行形如
//      `7f...-7f... r--p 6144000 fd:01 123 /path/base.apk`——offset 列是
//      so 在 APK 内的起始文件偏移，同一 APK 内可能映射多个 so，需要用
//      「该行的 start == dl_fbase」或 ELF 魔数校验来锁定目标行。
//   2. so 文件读取：路径含 `!/`（未解包 APK 内 so）→ 用 zip 中央目录解析
//      local file header，从 APK 文件里按 dataOffset 读出 so 字节；普通
//      路径直接 File 读。
//   3. OrtApiBase_vaddr = OrtGetApiBase() 返回值 - load_base。OrtGetApiBase
//      函数体只用 rip 相对寻址（leaq/adrp+add），**不经过数据重定位**，
//      返回值可信。
//   4. 解析 so 的 .rela.dyn（PT_DYNAMIC: DT_RELA/DT_RELASZ），建 off→addend
//      表；取 RELATIVE 条目（x86_64 type=8 / arm64 type=1027）。
//   5. GetApi 运行时地址 = load_base + rela[OrtApiBase_vaddr]；
//      GetVersionString = +8。
//   6. api = GetApi(27)——函数体自洽（版本比较 + leaq OrtApi 表），调用安全；
//      返回值 = load_base + OrtApi_vaddr。
//   7. OrtApi 第 i 槽运行时地址 = load_base + rela[OrtApi_vaddr + i*8]。
//      _bind 全部成员从自算地址 asFunction，绕开坏掉的内存槽值。
//
// 只读 so 文件与 /proc/self/maps，不写任何进程内存；RELA 缺条目时明确报错。
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

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

/// 定位结果。
class OrtLibLocation {
  OrtLibLocation({
    required this.loadBase,
    required this.soBytes,
    required this.soDesc,
  });

  /// so 第一映射（vaddr 0）的运行时基址。
  final int loadBase;

  /// so 的完整 ELF 文件字节（自愈解析 RELA 用）。
  final Uint8List soBytes;

  /// 人类可读的来源描述（诊断日志用）。
  final String soDesc;
}

/// dladdr 绑定：int (void*, Dl_info*)。Android linker（libdl.so）导出。
/// 公共类型：ort_ffi.dart 的 lookup 闭包签名要引用它。
typedef DlAddrC = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef DlAddrD = int Function(Pointer<Void>, Pointer<Void>);

/// 用 dladdr 从「可信函数指针」反查 so 基址与路径。
/// Dl_info 布局（bionic）：{ const char* dli_fname; void* dli_fbase;
/// const char* dli_sname; void* dli_saddr; }（指针大小按 ABI）。
OrtLibLocation? _locateViaDladdr(Pointer<Void> trustedFnPtr,
    Pointer<NativeFunction<DlAddrC>> Function(String) lookup) {
  final Pointer<NativeFunction<DlAddrC>> dladdr;
  try {
    dladdr = lookup('dladdr');
  } on Object {
    return null; // 平台无 dladdr（理论上 Android 都有），走 maps 回退。
  }
  final fn = dladdr.asFunction<DlAddrD>();
  final info = malloc<Uint8>(4 * sizeOf<Pointer<Void>>());
  try {
    final ok = fn(trustedFnPtr, info.cast());
    if (ok == 0) return null; // 地址不属于任何已知映射。
    final bd = ByteData.sublistView(info.asTypedList(4 * sizeOf<Pointer<Void>>()));
    final fname = bd.getPointer(0).cast<Utf8>().toDartString();
    final fbase = bd.getPointer(sizeOf<Pointer<Void>>()).address;
    return _loadSoBytes(fbase, fname);
  } finally {
    malloc.free(info);
  }
}

extension _ByteDataPointerExt on ByteData {
  Pointer<Void> getPointer(int byteOffset) =>
      Pointer<Void>.fromAddress(getUint64(byteOffset, Endian.little));
}

/// 从（可能含 `!/` 的）so 路径读出 ELF 字节 + 校验 fbase。
OrtLibLocation _loadSoBytes(int fbase, String rawPath) {
  final bang = rawPath.indexOf('!/');
  final apkPath = bang > 0 ? rawPath.substring(0, bang) : rawPath;
  final entryName = bang > 0 ? rawPath.substring(bang + 2) : null;
  final Uint8List bytes;
  var desc = rawPath;
  if (entryName != null) {
    bytes = _readZipEntry(apkPath, entryName);
    desc = '$rawPath（从 APK 内提取 ${bytes.length} 字节）';
  } else {
    bytes = File(apkPath).readAsBytesSync();
  }
  if (bytes.length < 64 ||
      bytes[0] != 0x7f ||
      bytes[1] != 0x45 ||
      bytes[2] != 0x4c ||
      bytes[3] != 0x46) {
    throw OrtRelocationException('读到的 so 不是 ELF（$desc）');
  }
  return OrtLibLocation(
      loadBase: fbase, soBytes: bytes, soDesc: desc);
}

/// 从 APK（zip）里读一个未压缩条目的原始字节。
/// AGP useLegacyPackaging=false 时 native lib STORED 且 16KB/4KB 对齐。
Uint8List _readZipEntry(String apkPath, String entryName) {
  final apk = File(apkPath).readAsBytesSync();
  final bd = ByteData.sublistView(apk);
  // 1. 从尾找 EOCD（0x06054b50），再向上找 ZIP64 EOCD locator（0x07064b50）。
  var eocd = -1;
  for (var i = apk.length - 22; i >= 0 && i > apk.length - 66000; i--) {
    if (bd.getUint32(i, Endian.little) == 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw OrtRelocationException('APK 无 EOCD（$apkPath）');
  var cdOff = bd.getUint32(eocd + 16, Endian.little);
  var cdCount = bd.getUint16(eocd + 10, Endian.little);
  if (cdOff == 0xffffffff || cdCount == 0xffff) {
    // ZIP64：locator 在 EOCD 前 20 字节。
    final loc = eocd - 20;
    if (bd.getUint32(loc, Endian.little) != 0x07064b50) {
      throw const OrtRelocationException('ZIP64 locator 缺失');
    }
    final z64Off = bd.getUint64(loc + 8, Endian.little);
    if (bd.getUint32(z64Off, Endian.little) != 0x06064b50) {
      throw const OrtRelocationException('ZIP64 EOCD 签名错');
    }
    cdOff = bd.getUint64(z64Off + 48, Endian.little);
    cdCount = bd.getUint64(z64Off + 32, Endian.little);
  }
  // 2. 遍历中央目录。
  final target = entryName.codeUnits;
  var pos = cdOff;
  for (var n = 0; n < cdCount; n++) {
    if (bd.getUint32(pos, Endian.little) != 0x02014b50) {
      throw OrtRelocationException('APK 中央目录损坏（entry $n）');
    }
    final nameLen = bd.getUint16(pos + 28, Endian.little);
    final extraLen = bd.getUint16(pos + 30, Endian.little);
    final commentLen = bd.getUint16(pos + 32, Endian.little);
    final method = bd.getUint16(pos + 10, Endian.little);
    final localOff = bd.getUint32(pos + 42, Endian.little);
    var match = nameLen == target.length;
    if (match) {
      for (var i = 0; i < nameLen; i++) {
        if (apk[pos + 46 + i] != target[i]) {
          match = false;
          break;
        }
      }
    }
    if (match) {
      // local file header：sig(4)+ver(2)+flag(2)+method(2)+time(2)+date(2)
      // +crc(4)+csize(4)+usize(4)+nameLen(2)+extraLen(2) = 30 字节头。
      final lNameLen = bd.getUint16(localOff + 26, Endian.little);
      final lExtraLen = bd.getUint16(localOff + 28, Endian.little);
      final dataOff = localOff + 30 + lNameLen + lExtraLen;
      final usize = bd.getUint32(pos + 24, Endian.little); // 中央目录的 usize
      if (method != 0) {
        throw OrtRelocationException('APK 内 $entryName 是压缩存储（method='
            '$method），无法直接映射读出');
      }
      return Uint8List.sublistView(apk, dataOff, dataOff + usize);
    }
    pos += 46 + nameLen + extraLen + commentLen;
  }
  throw OrtRelocationException('APK 内未找到条目 $entryName');
}

/// 定位 libonnxruntime.so：优先 dladdr（从 OrtGetApiBase 这个可信函数指针
/// 反查），失败回退 maps 扫描。返回基址 + so 的 ELF 字节。
OrtLibLocation locateLibrary(Pointer<Void> trustedFnPtr,
    Pointer<NativeFunction<DlAddrC>> Function(String) lookup) {
  // 1) dladdr 直答。
  final viaDl = _locateViaDladdr(trustedFnPtr, lookup);
  if (viaDl != null) {
    backendLog('[ffi-fix] dladdr 定位成功：base=0x'
        '${viaDl.loadBase.toRadixString(16)}、${viaDl.soDesc}');
    return viaDl;
  }
  // 2) maps 回退：找含 libonnxruntime.so 的行（base.apk 形态：offset 列=
  //    so 在 APK 内偏移；解包形态：offset=0）。用 ELF 魔数校验锁对行。
  final lines = File('/proc/self/maps').readAsLinesSync();
  final rowRe = RegExp(r'^([0-9a-f]+)-([0-9a-f]+) \S+ ([0-9a-f]+) \S+ \S+ (.+)$');
  for (final line in lines) {
    final m = rowRe.firstMatch(line);
    if (m == null) continue;
    final path = m.group(4)!;
    if (!path.contains('libonnxruntime.so')) continue;
    final start = int.parse(m.group(1)!, radix: 16);
    final fileOff = int.parse(m.group(3)!, radix: 16);
    final rawPath = fileOff == 0
        ? path
        : '$path!/${path.contains('/arm64') ? 'lib/arm64-v8a' : 'lib/x86_64'}/'
            'libonnxruntime.so';
    try {
      final loc = _loadSoBytes(start, rawPath);
      // 校验：ELF 头确实映射在这段内存开头。
      final head = Pointer<Uint8>.fromAddress(start);
      if (head[0] == 0x7f &&
          head[1] == 0x45 &&
          head[2] == 0x4c &&
          head[3] == 0x46) {
        backendLog('[ffi-fix] maps 定位成功：base=0x${start.toRadixString(16)}、'
            '${loc.soDesc}');
        return loc;
      }
    } on OrtRelocationException {
      continue; // 试下一行。
    }
  }
  throw const OrtRelocationException('无法定位 libonnxruntime.so：'
      'dladdr 失败且 maps 中没有可校验的 ELF 映射行');
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
/// [location] = locateLibrary() 的结果。
OrtRelocatedApi selfRelocate({
  required OrtLibLocation location,
  required Pointer<Void> apiBaseAddr,
}) {
  final so = location.soBytes;
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

  final loadBase = location.loadBase;
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
