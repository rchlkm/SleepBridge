import SwiftUI

struct DateRangeCalendarView: View {
  @Binding var startDay: Date
  @Binding var endDay: Date

  @State private var displayedMonth: Date
  @State private var dragAnchor: Date?

  private let calendar = Calendar.current
  private let rowHeight: CGFloat = 40

  init(startDay: Binding<Date>, endDay: Binding<Date>) {
    self._startDay = startDay
    self._endDay = endDay

    // Store displayedMonth as the first day of the month.
    let monthStart =
      calendar.date(
        from: calendar.dateComponents(
          [.year, .month],
          from: endDay.wrappedValue
        )
      ) ?? endDay.wrappedValue

    self._displayedMonth = State(initialValue: monthStart)
  }

  var body: some View {
    VStack(spacing: 8) {
      header
      weekdayLabels

      GeometryReader { geo in
        let cellWidth = geo.size.width / 7
        let rows = weeks

        VStack(spacing: 0) {
          ForEach(0..<rows.count, id: \.self) { row in
            HStack(spacing: 0) {
              ForEach(0..<7, id: \.self) { col in
                dayCell(
                  for: rows[row][col],
                  width: cellWidth
                )
              }
            }
          }
        }
        .contentShape(Rectangle())
        .gesture(
          dragGesture(
            cellWidth: cellWidth,
            rows: rows
          )
        )
      }
      .frame(height: CGFloat(weeks.count) * rowHeight)

      Text("\(rangeSummary)  •  min. 2 days")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  // MARK: - Month Navigation

  private func changeMonth(by amount: Int) {
    guard
      let newMonth = calendar.date(
        byAdding: .month,
        value: amount,
        to: displayedMonth
      )
    else {
      return
    }

    displayedMonth = newMonth
    clearSelection()
    dragAnchor = nil
  }

  private func clearSelection() {
    startDay = displayedMonth
    endDay = displayedMonth
  }

  // MARK: - Gesture

  private func dragGesture(
    cellWidth: CGFloat,
    rows: [[Date?]]
  ) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { value in
        guard
          let date = date(
            at: value.location,
            cellWidth: cellWidth,
            rows: rows
          )
        else {
          return
        }

        if dragAnchor == nil {
          dragAnchor = date
          startDay = date
          endDay = date
        } else if let anchor = dragAnchor {
          startDay = min(anchor, date)
          endDay = max(anchor, date)
        }
      }
      .onEnded { _ in
        dragAnchor = nil

        // Enforce a 2-calendar-day minimum span.
        //
        // If only one day was selected, extend the range by one day
        // without pushing endDay into the future.
        if calendar.dateComponents(
          [.day],
          from: startDay,
          to: endDay
        ).day ?? 0 < 1 {

          if let extendedEnd = calendar.date(
            byAdding: .day,
            value: 1,
            to: startDay
          ),
            extendedEnd <= maxSelectableDay
          {
            endDay = extendedEnd
          } else {
            startDay =
              calendar.date(
                byAdding: .day,
                value: -1,
                to: endDay
              ) ?? startDay
          }
        }
      }
  }

  private func date(
    at location: CGPoint,
    cellWidth: CGFloat,
    rows: [[Date?]]
  ) -> Date? {
    let col = Int(location.x / cellWidth)
    let row = Int(location.y / rowHeight)

    guard row >= 0,
      row < rows.count,
      col >= 0,
      col < 7
    else {
      return nil
    }

    guard let date = rows[row][col],
      date <= maxSelectableDay
    else {
      return nil
    }

    return date
  }

  /// Today is the latest selectable day.
  /// Sleep data for future dates doesn't exist.
  private var maxSelectableDay: Date {
    calendar.startOfDay(for: Date())
  }

  // MARK: - Layout Helpers

  private var rangeSummary: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d"

    return "\(formatter.string(from: startDay)) → \(formatter.string(from: endDay))"
  }

  private var header: some View {
    HStack {
      Button {
        changeMonth(by: -1)
      } label: {
        Image(systemName: "chevron.left")
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      Spacer()

      Text(monthTitle)
        .font(.headline)

      Spacer()

      Button {
        changeMonth(by: 1)
      } label: {
        Image(systemName: "chevron.right")
          .frame(width: 44, height: 44)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }

  private var monthTitle: String {
    let formatter = DateFormatter()
    formatter.dateFormat = "MMMM yyyy"

    return formatter.string(from: displayedMonth)
  }

  private var weekdayLabels: some View {
    HStack {
      ForEach(
        calendar.shortWeekdaySymbols,
        id: \.self
      ) { symbol in
        Text(symbol)
          .font(.caption2)
          .frame(maxWidth: .infinity)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// Grid of dates.
  /// Nil values represent leading/trailing cells outside
  /// the displayed month.
  private var weeks: [[Date?]] {
    guard
      let monthInterval = calendar.dateInterval(
        of: .month,
        for: displayedMonth
      ),
      let firstWeekInterval = calendar.dateInterval(
        of: .weekOfMonth,
        for: monthInterval.start
      )
    else {
      return []
    }

    var days: [Date?] = []
    var current = firstWeekInterval.start

    for _ in 0..<42 {
      if calendar.isDate(
        current,
        equalTo: displayedMonth,
        toGranularity: .month
      ) {
        days.append(current)
      } else {
        days.append(nil)
      }

      current =
        calendar.date(
          byAdding: .day,
          value: 1,
          to: current
        ) ?? current
    }

    return stride(
      from: 0,
      to: 42,
      by: 7
    ).map {
      Array(days[$0..<$0 + 7])
    }
  }

  @ViewBuilder
  private func dayCell(
    for date: Date?,
    width: CGFloat
  ) -> some View {
    ZStack {
      if let date {
        let isFuture = date > maxSelectableDay
        let isStart = calendar.isDate(
          date,
          inSameDayAs: startDay
        )
        let isEnd = calendar.isDate(
          date,
          inSameDayAs: endDay
        )
        let isEndpoint = isStart || isEnd

        let inRange =
          date >= calendar.startOfDay(for: startDay)
          && date <= calendar.startOfDay(for: endDay)

        let isToday = calendar.isDateInToday(date)

        RoundedRectangle(
          cornerRadius: isEndpoint ? 6 : 0
        )
        .fill(
          isEndpoint
            ? Color.accentColor
            : (inRange && !isFuture
              ? Color.accentColor.opacity(0.22)
              : Color.clear)
        )
        .padding(.vertical, 2)

        if isToday && !isEndpoint {
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(
              Color.accentColor,
              lineWidth: 1.5
            )
            .padding(2)
        }

        Text("\(calendar.component(.day, from: date))")
          .font(
            .caption.weight(
              isEndpoint ? .bold : .regular
            )
          )
          .foregroundStyle(
            isFuture
              ? Color.secondary.opacity(0.35)
              : (isEndpoint
                ? Color.white
                : Color.primary)
          )
      }
    }
    .frame(
      width: width,
      height: rowHeight
    )
  }
}

// MARK: - Preview

#Preview {
  PreviewWrapper()
}

private struct PreviewWrapper: View {
  @State private var startDay: Date =
    Calendar.current.date(
      byAdding: .day,
      value: -3,
      to: Date()
    ) ?? Date()

  @State private var endDay: Date = Date()

  var body: some View {
    VStack {
      DateRangeCalendarView(
        startDay: $startDay,
        endDay: $endDay
      )
      .padding()
      .background(Color(.systemBackground))
      .cornerRadius(12)
      .shadow(
        color: Color.black.opacity(0.05),
        radius: 10
      )
    }
    .padding()
    .background(
      Color(.systemGroupedBackground)
    )
  }
}
