import 'package:shared_preferences/shared_preferences.dart';

/// 「来电显示」首次启动引导的本地标记。
///
/// 只负责一件事：记住这次引导是否已经打扰过用户（点了「去开启」或「以后再说」
/// 都算处理过），让它一辈子只弹一次。
///
/// 真正的授权流程不在这里——权限申请、角色申请、跳系统设置全部留在
/// `CallerIdSettingsScreen` 里按用户操作触发（Android 11+ 连续两次拒绝会变成
/// 永久拒绝，首次启动绝不能替用户一次性甩完系统弹框）。
///
/// 单独用一个 key，不复用应用锁的 `applock_asked_once`：两条引导互相独立，
/// 将来任何一条要改版或重弹，都不会牵连另一条。
class CallerIdGuide {
  CallerIdGuide._();

  static const _kAsked = 'caller_id_guide_asked';

  /// 引导是否已处理过。
  ///
  /// 本地存储不可用时按「已处理」返回：宁可不引导，也不要在一台存不住标记的
  /// 设备上每次启动都弹一遍（重复打扰比漏掉一次引导更糟）。
  static Future<bool> askedOnce() async {
    try {
      final p = await SharedPreferences.getInstance();
      return p.getBool(_kAsked) ?? false;
    } catch (_) {
      return true;
    }
  }

  /// 标记引导已处理（用户明确选了开启或跳过）。
  static Future<void> markAsked() async {
    try {
      final p = await SharedPreferences.getInstance();
      await p.setBool(_kAsked, true);
    } catch (_) {}
  }
}
