import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'html_date_locale.dart';
import 'html_date_validation.dart';

/// Flutter calendar surface used by the native HTML date input.
///
/// This is rendered in an anchored overlay instead of a Material date dialog,
/// so its placement and controls follow the compact browser date-picker UI.
class NativeHtmlDateCalendar extends StatefulWidget {
  const NativeHtmlDateCalendar({
    super.key,
    required this.locale,
    required this.initialMonth,
    required this.initialFocusDate,
    required this.selectedDate,
    required this.minimum,
    required this.maximum,
    required this.min,
    required this.max,
    required this.step,
    required this.valueAttribute,
    required this.stepBase,
    required this.width,
    required this.onSelect,
    required this.onDismiss,
  });

  final NativeHtmlDateLocale locale;
  final DateTime initialMonth;
  final DateTime initialFocusDate;
  final DateTime? selectedDate;
  final DateTime minimum;
  final DateTime maximum;
  final String? min;
  final String? max;
  final String? step;
  final String? valueAttribute;
  final NativeHtmlDateValue stepBase;
  final double width;
  final ValueChanged<NativeHtmlDateValue?> onSelect;
  final VoidCallback onDismiss;

  @override
  State<NativeHtmlDateCalendar> createState() => _NativeHtmlDateCalendarState();
}

class _NativeHtmlDateCalendarState extends State<NativeHtmlDateCalendar> {
  late DateTime _month;
  late DateTime _focusDate;
  late final FocusNode _calendarFocus;
  bool _choosingYear = false;
  late final ScrollController _yearScrollController;

  @override
  void initState() {
    super.initState();
    _month = DateTime.utc(widget.initialMonth.year, widget.initialMonth.month);
    _focusDate = widget.initialFocusDate;
    _calendarFocus = FocusNode(debugLabel: 'native-html-date-calendar');
    _yearScrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _calendarFocus.requestFocus();
    });
  }

  @override
  void didUpdateWidget(covariant NativeHtmlDateCalendar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialMonth != widget.initialMonth) {
      _month = DateTime.utc(
        widget.initialMonth.year,
        widget.initialMonth.month,
      );
    }
    if (oldWidget.initialFocusDate != widget.initialFocusDate) {
      _focusDate = widget.initialFocusDate;
    }
  }

  @override
  void dispose() {
    _calendarFocus.dispose();
    _yearScrollController.dispose();
    super.dispose();
  }

  int get _firstYear => widget.minimum.year;
  int get _lastYear => widget.maximum.year;

  int get _daysInMonth => DateTime.utc(_month.year, _month.month + 1, 0).day;

  int get _leadingDays {
    final weekday = DateTime.utc(_month.year, _month.month, 1).weekday % 7;
    return (weekday - widget.locale.firstWeekday + 7) % 7;
  }

  int get _rowCount => ((_leadingDays + _daysInMonth + 6) ~/ 7).clamp(4, 6);

  NativeHtmlDateValue? _value(DateTime date) =>
      NativeHtmlDateValue.fromDateTime(date);

  bool _isSelectable(DateTime date) {
    final value = _value(date);
    if (value == null) return false;
    return !date.isBefore(widget.minimum) &&
        !date.isAfter(widget.maximum) &&
        NativeHtmlDateValidation.isSelectable(
          date: value,
          min: widget.min,
          max: widget.max,
          step: widget.step,
          valueAttribute: widget.valueAttribute,
          stepBase: widget.stepBase,
        );
  }

  DateTime _monthStart(DateTime value) => DateTime.utc(value.year, value.month);

  DateTime _monthEnd(DateTime value) =>
      DateTime.utc(value.year, value.month + 1, 0);

  bool _monthHasSelectableDate(DateTime month) {
    var start = _monthStart(month);
    var end = _monthEnd(month);
    if (start.isBefore(widget.minimum)) start = widget.minimum;
    if (end.isAfter(widget.maximum)) end = widget.maximum;
    if (start.isAfter(end)) return false;
    return NativeHtmlDateValidation.firstSelectable(
          from: NativeHtmlDateValue.fromDateTime(start)!,
          through: NativeHtmlDateValue.fromDateTime(end)!,
          min: widget.min,
          max: widget.max,
          step: widget.step,
          valueAttribute: widget.valueAttribute,
          stepBase: widget.stepBase,
        ) !=
        null;
  }

  DateTime? _firstSelectableInYear(int year) {
    for (var month = 1; month <= 12; month++) {
      final value = DateTime.utc(year, month);
      if (!_monthHasSelectableDate(value)) continue;
      var start = _monthStart(value);
      var end = _monthEnd(value);
      if (start.isBefore(widget.minimum)) start = widget.minimum;
      if (end.isAfter(widget.maximum)) end = widget.maximum;
      final first = NativeHtmlDateValidation.firstSelectable(
        from: NativeHtmlDateValue.fromDateTime(start)!,
        through: NativeHtmlDateValue.fromDateTime(end)!,
        min: widget.min,
        max: widget.max,
        step: widget.step,
        valueAttribute: widget.valueAttribute,
        stepBase: widget.stepBase,
      );
      final date = first?.toDateTime();
      if (date != null) return date;
    }
    return null;
  }

  DateTime? _shiftMonth(DateTime from, int delta) {
    final year = from.year + ((from.month - 1 + delta) ~/ 12);
    final month = ((from.month - 1 + delta) % 12) + 1;
    if (year < _firstYear || year > _lastYear) return null;
    final target = DateTime.utc(year, month);
    return _monthHasSelectableDate(target) ? target : null;
  }

  DateTime? _firstSelectableInMonth(DateTime month) {
    var start = _monthStart(month);
    var end = _monthEnd(month);
    if (start.isBefore(widget.minimum)) start = widget.minimum;
    if (end.isAfter(widget.maximum)) end = widget.maximum;
    if (start.isAfter(end)) return null;
    return NativeHtmlDateValidation.firstSelectable(
      from: NativeHtmlDateValue.fromDateTime(start)!,
      through: NativeHtmlDateValue.fromDateTime(end)!,
      min: widget.min,
      max: widget.max,
      step: widget.step,
      valueAttribute: widget.valueAttribute,
      stepBase: widget.stepBase,
    )?.toDateTime();
  }

  void _changeMonth(int delta) {
    final target = _shiftMonth(_month, delta);
    if (target == null) return;
    setState(() {
      _month = target;
      final day = math.min(_focusDate.day, _daysInMonthFor(target));
      final sameDay = DateTime.utc(target.year, target.month, day);
      _focusDate = _isSelectable(sameDay)
          ? sameDay
          : _firstSelectableInMonth(target) ?? sameDay;
    });
  }

  int _daysInMonthFor(DateTime date) =>
      DateTime.utc(date.year, date.month + 1, 0).day;

  void _moveFocus(DateTime candidate) {
    if (candidate.year < _firstYear || candidate.year > _lastYear) return;
    var next = candidate;
    final current = _value(candidate);
    if (current == null ||
        candidate.isBefore(widget.minimum) ||
        candidate.isAfter(widget.maximum)) {
      return;
    }
    // Keyboard motion skips dates disabled by min/max/step.
    final direction = candidate.isAfter(_focusDate) ? 1 : -1;
    for (var attempt = 0; attempt < 40000 && !_isSelectable(next); attempt++) {
      next = next.add(Duration(days: direction));
      if (next.year < _firstYear || next.year > _lastYear) return;
    }
    setState(() {
      _focusDate = DateTime.utc(next.year, next.month, next.day);
      _month = DateTime.utc(next.year, next.month);
      _choosingYear = false;
    });
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final rtl = Directionality.of(context) == TextDirection.rtl;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        widget.onDismiss();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _moveFocus(_focusDate.add(Duration(days: rtl ? 1 : -1)));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _moveFocus(_focusDate.add(Duration(days: rtl ? -1 : 1)));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _moveFocus(_focusDate.subtract(const Duration(days: 7)));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _moveFocus(_focusDate.add(const Duration(days: 7)));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageUp:
        _changeMonth(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.pageDown:
        _changeMonth(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.home:
        final weekday = _focusDate.weekday % 7;
        final offset = (weekday - widget.locale.firstWeekday + 7) % 7;
        _moveFocus(_focusDate.subtract(Duration(days: offset)));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.end:
        final weekday = _focusDate.weekday % 7;
        final offset = (weekday - widget.locale.firstWeekday + 7) % 7;
        _moveFocus(_focusDate.add(Duration(days: 6 - offset)));
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (_isSelectable(_focusDate)) {
          widget.onSelect(_value(_focusDate));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.delete:
      case LogicalKeyboardKey.backspace:
        widget.onSelect(null);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _showYears() {
    setState(() => _choosingYear = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_yearScrollController.hasClients) return;
      final yearTileHeight = ((widget.width - 16) / 3) / 2.1;
      final row = (_month.year - _firstYear) ~/ 3;
      final offset = row * yearTileHeight;
      _yearScrollController.jumpTo(
        offset.clamp(0.0, _yearScrollController.position.maxScrollExtent),
      );
    });
  }

  void _selectYear(int year) {
    final requestedMonth = DateTime.utc(year, _month.month);
    final first = _monthHasSelectableDate(requestedMonth)
        ? _firstSelectableInMonth(requestedMonth)
        : _firstSelectableInYear(year);
    if (first == null) return;
    final requestedDay = DateTime.utc(
      year,
      first.month,
      math.min(_focusDate.day, _daysInMonthFor(first)),
    );
    setState(() {
      _month = DateTime.utc(year, first.month);
      _focusDate = _isSelectable(requestedDay) ? requestedDay : first;
      _choosingYear = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final scale = MediaQuery.textScalerOf(context).scale(1);
    final surface = dark ? const Color(0xff292929) : Colors.white;
    final textColor = dark ? const Color(0xffeeeeee) : const Color(0xff202124);
    final mutedColor = dark ? const Color(0xff9e9e9e) : const Color(0xff70757a);
    final accent = dark ? const Color(0xff8ab4f8) : const Color(0xff1a73e8);
    final cellHeight = math.max(28.0, 30.0 * scale);
    final cellWidth = (widget.width - 16 * scale) / 7;
    final popupRadius = BorderRadius.circular(4);
    final top = _monthStart(_month);
    final leading = _leadingDays;
    final rowCount = _rowCount;

    Widget monthNavigationButton({
      required IconData icon,
      required String label,
      required bool enabled,
      required VoidCallback onPressed,
    }) => IconButton(
      tooltip: label,
      onPressed: enabled ? onPressed : null,
      visualDensity: VisualDensity.compact,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(
        width: 32 * scale,
        height: 34 * scale,
      ),
      icon: Icon(icon, size: 20 * scale),
    );

    Widget dayCell(int index) {
      final date = top.add(Duration(days: index - leading));
      final inMonth = date.month == _month.month;
      final enabled = _isSelectable(date);
      final selected =
          widget.selectedDate != null &&
          date.year == widget.selectedDate!.year &&
          date.month == widget.selectedDate!.month &&
          date.day == widget.selectedDate!.day;
      final today =
          _today().year == date.year &&
          _today().month == date.month &&
          _today().day == date.day;
      final focused =
          date.year == _focusDate.year &&
          date.month == _focusDate.month &&
          date.day == _focusDate.day;
      final fg = !enabled
          ? mutedColor.withValues(alpha: .4)
          : selected
          ? Colors.white
          : inMonth
          ? textColor
          : mutedColor.withValues(alpha: .5);
      final dateLabel = widget.locale.accessibleDate(
        date.year,
        date.month,
        date.day,
      );
      return SizedBox(
        width: cellWidth,
        height: cellHeight,
        child: Semantics(
          button: true,
          selected: selected,
          enabled: enabled,
          label: dateLabel,
          child: Tooltip(
            message: dateLabel,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: enabled ? () => widget.onSelect(_value(date)) : null,
                borderRadius: BorderRadius.circular(4),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: selected ? accent : Colors.transparent,
                    borderRadius: BorderRadius.circular(3),
                    border: focused && !selected
                        ? Border.all(color: accent, width: 1)
                        : today && !selected
                        ? Border.all(color: accent.withValues(alpha: .7))
                        : null,
                  ),
                  child: Center(
                    child: Text(
                      '${date.day}',
                      style: TextStyle(
                        fontSize: 13 * scale,
                        height: kTextHeightNone,
                        color: fg,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    final targetMonthBefore = _shiftMonth(_month, -1);
    final targetMonthAfter = _shiftMonth(_month, 1);
    final today = _today();
    final todayEnabled = _isSelectable(today);
    final popup = Material(
      key: const ValueKey('native-html-date-calendar-popup'),
      color: surface,
      elevation: 2,
      shadowColor: const Color(0x33000000),
      surfaceTintColor: Colors.transparent,
      borderRadius: popupRadius,
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        width: widget.width,
        child: Focus(
          focusNode: _calendarFocus,
          autofocus: true,
          onKeyEvent: _onKeyEvent,
          child: Padding(
            padding: EdgeInsets.all(8 * scale),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        onPressed: _showYears,
                        style: TextButton.styleFrom(
                          foregroundColor: textColor,
                          padding: EdgeInsets.symmetric(horizontal: 4 * scale),
                          minimumSize: Size(0, 34 * scale),
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        iconAlignment: IconAlignment.end,
                        icon: Icon(Icons.arrow_drop_down, size: 20 * scale),
                        label: Align(
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(
                            widget.locale.monthTitle(_month.year, _month.month),
                            style: TextStyle(
                              fontSize: 14 * scale,
                              height: kTextHeightNone,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                    monthNavigationButton(
                      icon: Icons.chevron_left,
                      label: widget.locale.previousMonth,
                      enabled: targetMonthBefore != null,
                      onPressed: () => _changeMonth(-1),
                    ),
                    monthNavigationButton(
                      icon: Icons.chevron_right,
                      label: widget.locale.nextMonth,
                      enabled: targetMonthAfter != null,
                      onPressed: () => _changeMonth(1),
                    ),
                  ],
                ),
                SizedBox(height: 4 * scale),
                if (_choosingYear)
                  SizedBox(
                    height: math.min(216 * scale, 360),
                    child: GridView.builder(
                      controller: _yearScrollController,
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 3,
                            childAspectRatio: 2.1,
                          ),
                      itemCount: _lastYear - _firstYear + 1,
                      itemBuilder: (context, index) {
                        final year = _firstYear + index;
                        final enabled = _firstSelectableInYear(year) != null;
                        final selected = year == _month.year;
                        return TextButton(
                          onPressed: enabled ? () => _selectYear(year) : null,
                          style: TextButton.styleFrom(
                            foregroundColor: selected ? accent : textColor,
                            backgroundColor: selected
                                ? accent.withValues(alpha: .14)
                                : null,
                            padding: EdgeInsets.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: Text('$year'),
                        );
                      },
                    ),
                  )
                else ...[
                  Row(
                    children: [
                      for (var index = 0; index < 7; index++)
                        SizedBox(
                          width: cellWidth,
                          height: 24 * scale,
                          child: Center(
                            child: Text(
                              widget.locale.weekdays[index],
                              style: TextStyle(
                                color: mutedColor,
                                fontSize: 11 * scale,
                                height: kTextHeightNone,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                  for (var row = 0; row < rowCount; row++)
                    Row(
                      children: [
                        for (var column = 0; column < 7; column++)
                          dayCell(row * 7 + column),
                      ],
                    ),
                ],
                SizedBox(height: 4 * scale),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    TextButton(
                      onPressed: () => widget.onSelect(null),
                      style: TextButton.styleFrom(
                        foregroundColor: accent,
                        padding: EdgeInsets.symmetric(horizontal: 8 * scale),
                        minimumSize: Size(0, 32 * scale),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        widget.locale.clear,
                        style: TextStyle(fontSize: 12 * scale),
                      ),
                    ),
                    TextButton(
                      onPressed: todayEnabled
                          ? () => widget.onSelect(_value(today))
                          : null,
                      style: TextButton.styleFrom(
                        foregroundColor: accent,
                        padding: EdgeInsets.symmetric(horizontal: 8 * scale),
                        minimumSize: Size(0, 32 * scale),
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                      child: Text(
                        widget.locale.today,
                        style: TextStyle(fontSize: 12 * scale),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return PopScope<Object?>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) widget.onDismiss();
      },
      child: popup,
    );
  }

  DateTime _today() {
    final now = DateTime.now();
    return DateTime.utc(now.year, now.month, now.day);
  }
}
