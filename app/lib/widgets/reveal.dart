import 'package:flutter/material.dart';

/// 全 App 共用的「出現／消失」與「展開／收合」過場。
///
/// **節奏只有一組**：同一個畫面上兩塊東西用不同的秒數或曲線展開，會讓比較
/// 慢的那塊看起來像卡住了。所以參數放在這裡，不在各個點位手刻。
///
/// 短、收尾偏線性、不做彈跳——這些都是常開常關的工作面板與清單，過場太長
/// 就是擋在人和內容之間。
const Duration kUepRevealDuration = Duration(milliseconds: 180);
const Curve kUepRevealIn = Curves.easeOutCubic;
const Curve kUepRevealOut = Curves.easeInCubic;

/// 「出現／消失」：本來完全不在畫面上的一塊東西（橫幅、抽屜、疊上去的面板）。
///
/// [child] 為 null＝不在。**收起時 child 不建**，與原本的條件渲染一樣，只是
/// 多了進場與退場。
///
/// 退場靠 [AnimatedSwitcher] 而不是隱式動畫：child 在收起的那一刻就不存在
/// 了，沒有東西可以動——AnimatedSwitcher 會把舊的那一個留到過場結束，離開
/// 才看得見。只有進場有動畫、消失是瞬間的，比兩邊都沒有更突兀。
class UepReveal extends StatelessWidget {
  const UepReveal({
    super.key,
    this.child,
    this.slide = Offset.zero,
    this.grow = false,
    this.axis = Axis.vertical,
    this.alignment = Alignment.topCenter,
  });

  /// null＝收起來。
  final Widget? child;

  /// 進場位移的起點，單位是自己的尺寸（`Offset(.04, 0)`＝自右側 4% 滑入）。
  ///
  /// ⚠️ 位移吃的是**整個 child**。child 裡含遮罩之類「必須蓋滿」的東西時
  /// 不要用，那會在過場中露出一條沒遮到的底。
  final Offset slide;

  /// 同時撐高／收合。插在一串內容中間的東西（橫幅、清單裡的一段）要開，
  /// 否則它出現的那一格會把下面整串瞬間推走；本來就吃滿版面的面板（抽屜、
  /// 疊層）不要開。
  final bool grow;

  /// [grow] 的方向。橫向排列裡的東西要給 [Axis.horizontal]。
  final Axis axis;

  /// 進出場並存的那幾格要靠哪一邊對齊。
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: kUepRevealDuration,
      switchInCurve: kUepRevealIn,
      switchOutCurve: kUepRevealOut,
      layoutBuilder: (current, previous) => Stack(
        alignment: alignment,
        children: [
          ...previous,
          ?current,
        ],
      ),
      transitionBuilder: (c, animation) {
        Widget out = FadeTransition(opacity: animation, child: c);
        if (slide != Offset.zero) {
          out = SlideTransition(
            position: Tween<Offset>(begin: slide, end: Offset.zero)
                .animate(animation),
            child: out,
          );
        }
        if (grow) {
          out = SizeTransition(
            sizeFactor: animation,
            axis: axis,
            // 貼著起點長出來，不是從中間往兩邊撐開
            alignment: AlignmentDirectional.topStart,
            child: out,
          );
        }
        return out;
      },
      // key 固定：child 換內容時是換內容，不是關掉再開一塊
      child: child == null
          ? const SizedBox.shrink()
          : KeyedSubtree(key: const ValueKey('uep-reveal'), child: child!),
    );
  }
}

/// 「展開／收合」：標題列一直在，底下那一段開開關關。
///
/// 就是撐高版的 [UepReveal]——收合時內容一邊淡出一邊縮起來，而不是先整段
/// 消失再留一塊空白慢慢閉合（那是 `AnimatedSize` 的行為：它只留得住尺寸，
/// 留不住已經被移除的 child）。
class UepExpand extends StatelessWidget {
  const UepExpand({
    super.key,
    required this.expanded,
    required this.child,
    this.alignment = Alignment.topCenter,
  });

  final bool expanded;
  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => UepReveal(
        grow: true,
        alignment: alignment,
        child: expanded ? child : null,
      );
}

/// 「內容自己變高變矮」：東西一直在，只是筆數或行數換了（換過濾條件、
/// 多了一列）。
///
/// 這一種沒有進出場可言，動的是尺寸本身，所以用 [AnimatedSize]；[ClipRect]
/// 擋住縮的那一格裡溢出來的內容。
class UepResize extends StatelessWidget {
  const UepResize({
    super.key,
    required this.child,
    this.alignment = Alignment.topCenter,
  });

  final Widget child;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) => ClipRect(
        child: AnimatedSize(
          duration: kUepRevealDuration,
          curve: kUepRevealIn,
          alignment: alignment,
          child: child,
        ),
      );
}
