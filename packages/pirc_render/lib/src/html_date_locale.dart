import 'package:flutter/widgets.dart';

/// Host-locale presentation for a native HTML date control.
///
/// The surrounding page's `lang`/locale does not control the browser chrome
/// used to edit an `<input type="date">`. Resolve this from the host locale,
/// or inject it explicitly when the host and app locales differ.
@immutable
class NativeHtmlDateLocale {
  const NativeHtmlDateLocale._({
    required this.locale,
    required this.order,
    required this.separator,
    required this.placeholders,
    required this.segmentLabels,
    required this.chooseDate,
    required this.clear,
    required this.today,
    required this.previousMonth,
    required this.nextMonth,
    required this.dismiss,
    required this.weekdays,
    required this.firstWeekday,
    required this.monthNames,
    required this.yearSuffix,
    required this.monthSuffix,
    required this.daySuffix,
  });

  final Locale locale;

  /// Segment names in the order used by the host's date control.
  final List<String> order;
  final String separator;
  final Map<String, String> placeholders;
  final Map<String, String> segmentLabels;
  final String chooseDate;
  final String clear;
  final String today;
  final String previousMonth;
  final String nextMonth;
  final String dismiss;
  final List<String> weekdays;

  /// Sunday is 0, Monday is 1, through Saturday at 6.
  final int firstWeekday;
  final List<String> monthNames;
  final String yearSuffix;
  final String monthSuffix;
  final String daySuffix;

  factory NativeHtmlDateLocale.forLocale(Locale locale) {
    final language = locale.languageCode.toLowerCase();
    final region = (locale.countryCode ?? '').toUpperCase();
    if (language == 'zh') {
      final traditional = region == 'TW' || region == 'HK' || region == 'MO';
      return NativeHtmlDateLocale._(
        locale: locale,
        order: const ['year', 'month', 'day'],
        separator: '/',
        placeholders: const {'year': '年', 'month': '月', 'day': '日'},
        segmentLabels: const {'year': '年', 'month': '月', 'day': '日'},
        chooseDate: traditional ? '選擇日期' : '选择日期',
        clear: traditional ? '清除' : '清除',
        today: traditional ? '今天' : '今天',
        previousMonth: traditional ? '上個月' : '上个月',
        nextMonth: traditional ? '下個月' : '下个月',
        dismiss: traditional ? '關閉日期選擇器' : '关闭日期选择器',
        weekdays: traditional
            ? const ['日', '一', '二', '三', '四', '五', '六']
            : const ['日', '一', '二', '三', '四', '五', '六'],
        firstWeekday: 0,
        monthNames: const [],
        yearSuffix: '年',
        monthSuffix: '月',
        daySuffix: '日',
      );
    }
    if (language == 'ja') {
      return NativeHtmlDateLocale._(
        locale: locale,
        order: const ['year', 'month', 'day'],
        separator: '/',
        placeholders: const {'year': '年', 'month': '月', 'day': '日'},
        segmentLabels: const {'year': '年', 'month': '月', 'day': '日'},
        chooseDate: '日付を選択',
        clear: 'クリア',
        today: '今日',
        previousMonth: '前の月',
        nextMonth: '次の月',
        dismiss: '日付選択を閉じる',
        weekdays: const ['日', '月', '火', '水', '木', '金', '土'],
        firstWeekday: 0,
        monthNames: const [],
        yearSuffix: '年',
        monthSuffix: '月',
        daySuffix: '日',
      );
    }
    if (language == 'ko') {
      return NativeHtmlDateLocale._(
        locale: locale,
        order: const ['year', 'month', 'day'],
        separator: '.',
        placeholders: const {'year': '년', 'month': '월', 'day': '일'},
        segmentLabels: const {'year': '년', 'month': '월', 'day': '일'},
        chooseDate: '날짜 선택',
        clear: '지우기',
        today: '오늘',
        previousMonth: '이전 달',
        nextMonth: '다음 달',
        dismiss: '날짜 선택 닫기',
        weekdays: const ['일', '월', '화', '수', '목', '금', '토'],
        firstWeekday: 0,
        monthNames: const [],
        yearSuffix: '년',
        monthSuffix: '월',
        daySuffix: '일',
      );
    }

    final usOrder =
        language == 'en' &&
        (region == 'US' || region == 'PH' || region == 'BZ');
    final english = language == 'en';
    final sundayStart =
        usOrder ||
        region == 'CA' ||
        region == 'JP' ||
        region == 'KR' ||
        region == 'TW' ||
        region == 'HK';
    return NativeHtmlDateLocale._(
      locale: locale,
      order: usOrder
          ? const ['month', 'day', 'year']
          : const ['day', 'month', 'year'],
      separator: english ? '/' : '.',
      placeholders: usOrder
          ? const {'month': 'MM', 'day': 'DD', 'year': 'YYYY'}
          : const {'day': 'DD', 'month': 'MM', 'year': 'YYYY'},
      segmentLabels: const {'month': 'month', 'day': 'day', 'year': 'year'},
      chooseDate: english ? 'Choose date' : 'Choose date',
      clear: english ? 'Clear' : 'Clear',
      today: english ? 'Today' : 'Today',
      previousMonth: english ? 'Previous month' : 'Previous month',
      nextMonth: english ? 'Next month' : 'Next month',
      dismiss: english ? 'Dismiss date picker' : 'Dismiss date picker',
      weekdays: sundayStart
          ? const ['S', 'M', 'T', 'W', 'T', 'F', 'S']
          : const ['M', 'T', 'W', 'T', 'F', 'S', 'S'],
      firstWeekday: sundayStart ? 0 : 1,
      monthNames: const [
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December',
      ],
      yearSuffix: '',
      monthSuffix: '',
      daySuffix: '',
    );
  }

  String placeholder(String segment) => placeholders[segment] ?? segment;

  String labelFor(String segment) => segmentLabels[segment] ?? segment;

  String monthTitle(int year, int month) {
    if (yearSuffix.isNotEmpty) {
      final yearText = year.toString().padLeft(4, '0');
      return '$yearText$yearSuffix${month.toString().padLeft(2, '0')}$monthSuffix';
    }
    return '${monthNames[month - 1]} $year';
  }

  String accessibleDate(int year, int month, int day) {
    if (yearSuffix.isNotEmpty) {
      final yearText = year.toString().padLeft(4, '0');
      return '$yearText$yearSuffix$month$monthSuffix$day$daySuffix';
    }
    if (order.first == 'month') {
      return '${monthNames[month - 1]} $day, $year';
    }
    return '$day ${monthNames[month - 1]} $year';
  }
}
