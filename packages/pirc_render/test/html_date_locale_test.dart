import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/html_date_locale.dart';

void main() {
  test('Taiwan host locale formats date-control chrome independently', () {
    final locale = NativeHtmlDateLocale.forLocale(const Locale('zh', 'TW'));

    expect(locale.order, ['year', 'month', 'day']);
    expect(locale.separator, '/');
    expect(locale.placeholder('year'), '年');
    expect(locale.placeholder('month'), '月');
    expect(locale.placeholder('day'), '日');
    expect(locale.chooseDate, '選擇日期');
    expect(locale.clear, '清除');
    expect(locale.today, '今天');
    expect(locale.weekdays, ['日', '一', '二', '三', '四', '五', '六']);
    expect(locale.monthTitle(2024, 6), '2024年06月');
    expect(locale.accessibleDate(2024, 6, 15), '2024年6月15日');
  });

  test('common English host locales keep their own segment order', () {
    final us = NativeHtmlDateLocale.forLocale(const Locale('en', 'US'));
    final uk = NativeHtmlDateLocale.forLocale(const Locale('en', 'GB'));

    expect(us.order, ['month', 'day', 'year']);
    expect(us.firstWeekday, 0);
    expect(us.monthTitle(2024, 6), 'June 2024');
    expect(uk.order, ['day', 'month', 'year']);
    expect(uk.firstWeekday, 1);
  });
}
