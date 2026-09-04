import 'package:pinyin/pinyin.dart';

/// 联系人拼音搜索工具。
///
/// 支持两种搜索模式：
/// - **全拼搜索**：输入 "zhangwei" 匹配 "张伟"，输入 "yanfa" 匹配"研发部"
/// - **首字母搜索**：输入 "zw" 匹配 "张伟"，输入 "yfb" 匹配"研发部"
///
/// 覆盖字段：姓名、部门名称、职务、电话号码。
class PinyinSearch {
  // 拼音缓存 key → _PinyinResult
  static final Map<String, _PinyinResult> _cache = {};

  /// 为任意中文字符串计算拼音索引。
  static _PinyinResult _compute(String text) {
    final chars = text.characters;

    String fullPinyin = '';
    String firstLetters = '';

    for (final c in chars) {
      if (_isChinese(c)) {
        try {
          final p = PinyinHelper.getPinyin(c, separator: '').toLowerCase();
          fullPinyin += p;
          firstLetters += p.isNotEmpty ? p[0] : '';
        } catch (_) {
          fullPinyin += c;
          firstLetters += c;
        }
      } else {
        fullPinyin += c.toLowerCase();
        firstLetters += c.toLowerCase();
      }
    }

    return _PinyinResult(
      fullPinyin: fullPinyin,
      firstLetters: firstLetters,
    );
  }

  /// 判断联系人是否匹配查询。
  ///
  /// 会分别对 [displayName] [groupKey] [jobTitle] 做拼音转换后匹配，
  /// 同时对 [rawContactText] 做原文匹配。
  static bool matches({
    required String rawContactText,
    required String displayName,
    required String groupKey,
    required String? jobTitle,
    required String query,
  }) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return true;

    // 1) 原文匹配（姓名、电话、部门、职务）
    if (rawContactText.toLowerCase().contains(q)) return true;

    // 2) 拼音匹配：姓名
    final namePinyin = _cache.putIfAbsent('name:$displayName', () => _compute(displayName));
    if (namePinyin.fullPinyin.contains(q) || namePinyin.firstLetters.contains(q)) {
      return true;
    }

    // 3) 拼音匹配：部门
    final deptPinyin = _cache.putIfAbsent('dept:$groupKey', () => _compute(groupKey));
    if (deptPinyin.fullPinyin.contains(q) || deptPinyin.firstLetters.contains(q)) {
      return true;
    }

    // 4) 拼音匹配：职务
    if (jobTitle != null && jobTitle.isNotEmpty) {
      final titlePinyin = _cache.putIfAbsent('title:$jobTitle', () => _compute(jobTitle));
      if (titlePinyin.fullPinyin.contains(q) || titlePinyin.firstLetters.contains(q)) {
        return true;
      }
    }

    return false;
  }

  /// 清除拼音缓存（数据刷新时可调用）。
  static void clearCache() => _cache.clear();

  static bool _isChinese(String c) {
    final rune = c.runes.firstOrNull ?? 0;
    return rune >= 0x4E00 && rune <= 0x9FFF;
  }
}

extension on String {
  Iterable<String> get characters => split('');
}

class _PinyinResult {
  final String fullPinyin;
  final String firstLetters;

  const _PinyinResult({
    required this.fullPinyin,
    required this.firstLetters,
  });
}
